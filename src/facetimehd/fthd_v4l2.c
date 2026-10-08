/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * FacetimeHD camera driver
 *
 * Copyright (C) 2015 Sven Schnelle <svens@stackframe.org>
 *
 */

#include <linux/kernel.h>
#include <linux/spinlock.h>
#include <linux/version.h>
#include <linux/videodev2.h>
#include <media/v4l2-dev.h>
#include <media/v4l2-ioctl.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-event.h>
#include <media/videobuf2-dma-sg.h>
#include "fthd_drv.h"
#include "fthd_hw.h"
#include "fthd_isp.h"
#include "fthd_ringbuf.h"
#include "fthd_buffer.h"

/* Fallback ceiling used only if the sensor's native size wasn't detected.
 * The real per-device limit is dev_priv->sensor_width/height. */
#define FTHD_MAX_WIDTH 1280
#define FTHD_MAX_HEIGHT 720
#define FTHD_MIN_WIDTH 320
#define FTHD_MIN_HEIGHT 240
#define FTHD_PROTOCOL_ERROR_LIMIT 4

/*
 * The ISP's current correlated-colour-temperature estimate, read straight out
 * of CISP_CMD_CH_AWB_CCT_GET.
 *
 * It is a driver-private CID rather than V4L2_CID_WHITE_BALANCE_TEMPERATURE
 * because that standard control means the temperature the *application* asks
 * the camera to assume, and is expected to be writable and paired with a manual
 * AWB mode.  This is the opposite: a measurement the ISP produces, with no way
 * to write it - the manual AWB-CCT setter carries a second payload word whose
 * meaning is still unidentified, so it stays unexposed.  Publishing a
 * measurement under a CID that means a set point would make an application that
 * wrote it silently get nothing.
 *
 * The kelvin unit is hardware evidence rather than a guess - under warm light
 * this firmware reported 2652 and under cool light 5777, with the right
 * ordering and realistic magnitudes - but it is one machine, so
 * FIRMWARE-REVERSE-ENGINEERING.md still lists cross-model confirmation as open.
 * A private CID is also what keeps that caveat honest: nothing in userspace has
 * a standing expectation about what this control means.
 *
 * 0x1001 and 0x1002 were used by the removed noise-reduction and
 * chroma-suppression controls.  Starting at 0x1003 keeps anything built against
 * that short-lived series from binding to a control with different semantics.
 */
#define FTHD_CID_AWB_CCT_ESTIMATE (V4L2_CID_USER_BASE | 0x1003)

/* Wide enough for any plausible illuminant without asserting a tighter range
 * than one machine's readings support. */
#define FTHD_AWB_CCT_MIN 0
#define FTHD_AWB_CCT_MAX 65535

/*
 * The ISP's semi-planar output, format code 0, is NV12.  Measured on a
 * MacBookAir7,2: a width*height luma plane followed by exactly width*height/2
 * of chroma, with Cb/Cr means within 0.2 of a YUYV capture of the same scene.
 * NV16 is not offered because no code produces it.
 *
 * NV12 is enumerated first and is the default: a frame is three quarters of a
 * packed one, and the simple code that takes index 0 mostly feeds a display or
 * a 4:2:0 encoder.  Negotiating applications name their format, so the order
 * does not reach them.  Whether code 0 is native 4:2:0 or a downsample of 4:2:2
 * chroma is not established - chroma means cannot tell - and nothing here
 * depends on it.
 */

/* The only rate the sensor delivers.  Everything the driver reports is derived
 * from it, so G_PARM, S_PARM and ENUM_FRAMEINTERVALS cannot contradict each
 * other. */
#define FTHD_FPS 30

/*
 * Slower capture rates are produced by delivering one sensor frame in N and
 * handing the rest straight back to the ISP, so the rate the application asks
 * for is the rate it gets, exactly: the divisor is applied to frames the driver
 * has already received, so G_PARM cannot disagree with the stream.
 *
 * The ISP's AE frame-rate window (CISP_CMD_CH_AE_FRAME_RATE_{MIN,MAX}_SET) is
 * held at 30 fps by fthd_start_channel().  Whether lowering it lowers the
 * delivered rate has not been measured here, so S_PARM does not use it.
 *
 * The ISP still runs at full rate, so this saves bus and CPU work in the
 * application, not power in the camera.
 */
#define FTHD_MAX_FPS_DIVISOR FTHD_FPS

/*
 * True when the chroma plane lives at an offset inside the same buffer rather
 * than interleaved with luma.  Derived from the format on every use instead of
 * being cached in a plane count: the vb2 queue is single-planar in every case.
 */
static bool fthd_format_semiplanar(u32 pixelformat)
{
	return pixelformat == V4L2_PIX_FMT_NV12;
}

static int fthd_buffer_queue_setup(
    struct vb2_queue *vq,
    unsigned int *nbuffers,
    unsigned int *nplanes,
    unsigned int sizes[],
    struct device *alloc_devs[]
) {

	struct fthd_private *dev_priv = vb2_get_drv_priv(vq);
	struct v4l2_pix_format *cur_fmt = &dev_priv->fmt.fmt;
	unsigned long budget = 16 * 1024 * 1024;
	unsigned long size;
	unsigned int i, allocated, slots, limit;
	bool create = *nplanes != 0;

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 8, 0)
	allocated = vb2_get_num_buffers(vq);
	slots = vq->max_num_buffers;
#else
	allocated = vq->num_buffers;
	slots = vq->num_buffers;
#endif
	if (create) {
		if (*nplanes != 1 || sizes[0] < cur_fmt->sizeimage)
			return -EINVAL;
	} else {
		*nplanes = 1;
		sizes[0] = cur_fmt->sizeimage;
	}

	size = PAGE_ALIGN((unsigned long)sizes[0]);
	if (!size)
		return -ENOMEM;

	if (create) {
		/*
		 * CREATE_BUFS asks for buffers on top of the ones already
		 * there, so those are charged against the budget and against
		 * the context count.
		 */
		for (i = 0; i < slots; i++) {
			struct vb2_buffer *vb;
			unsigned long used;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 8, 0)
			vb = vb2_get_buffer(vq, i);
#else
			vb = vq->bufs[i];
#endif
			if (!vb)
				continue;
			used = PAGE_ALIGN((unsigned long)vb2_plane_size(vb, 0));
			if (!used || used >= budget)
				return -ENOMEM;
			budget -= used;
		}
		if (allocated >= FTHD_BUFFERS)
			return -ENOBUFS;
		if (size > budget)
			return -ENOMEM;
		limit = min_t(unsigned int, FTHD_BUFFERS - allocated,
			      budget / size);
		*nbuffers = min(*nbuffers, limit);
		if (!*nbuffers)
			return -ENOMEM;
	} else {
		/*
		 * REQBUFS asks for a total. vb2 calls back a second time to
		 * confirm a partial allocation, and the buffers it asks about
		 * then are the ones already allocated, so charging them here
		 * would reject a count that is in fact usable.
		 */
		if (size > budget)
			return -ENOMEM;
		limit = min_t(unsigned int, FTHD_BUFFERS, budget / size);
		*nbuffers = min(max(*nbuffers, 2U), limit);
		if (*nbuffers < 2)
			return -ENOMEM;
	}

	alloc_devs[0] = &dev_priv->pdev->dev;
	return 0;
}

/*
 * Free the ISP-side memory a prepared buffer owns and put its slot back on the
 * free list.  The buffer must no longer be queued to the firmware, and the
 * hardware must still be up: both isp_mem_destroy() and iommu_free() write S2
 * registers.
 */
static void fthd_release_buffer_ctx(struct fthd_private *dev_priv,
				    struct h2t_buf_ctx *ctx)
{
	struct isp_mem_obj *dma_desc_obj;
	struct iommu_obj *planes[ARRAY_SIZE(dev_priv->h2t_bufs[0].plane)];
	unsigned long flags;
	int i;

	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	if (ctx->state == BUF_FREE) {
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
		return;
	}

	ctx->state = BUF_FREE;
	ctx->vb = NULL;
	dma_desc_obj = ctx->dma_desc_obj;
	ctx->dma_desc_obj = NULL;
	for (i = 0; i < ARRAY_SIZE(ctx->plane); i++) {
		planes[i] = ctx->plane[i];
		ctx->plane[i] = NULL;
	}
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

	isp_mem_destroy(dma_desc_obj);
	for (i = 0; i < ARRAY_SIZE(planes); i++)
		iommu_free(dev_priv, planes[i]);
}

/*
 * The hardware slot a vb2 buffer owns, or NULL if it has none.  Call with
 * buffer_lock held, and keep holding it for as long as the returned slot is
 * used: only that lock keeps the state and the vb pointer consistent with the
 * interrupt handler.
 */
static struct h2t_buf_ctx *fthd_ctx_for_vb(struct fthd_private *dev_priv,
					   struct vb2_buffer *vb)
{
	int i;

	for (i = 0; i < FTHD_BUFFERS; i++) {
		if (dev_priv->h2t_bufs[i].vb == vb)
			return dev_priv->h2t_bufs + i;
	}

	return NULL;
}

static void fthd_buffer_cleanup(struct vb2_buffer *vb)
{
	struct fthd_private *dev_priv = vb2_get_drv_priv(vb->vb2_queue);
	struct h2t_buf_ctx *ctx;
	unsigned long flags;

	pr_debug("%p\n", vb);
	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	ctx = fthd_ctx_for_vb(dev_priv, vb);
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

	if (ctx)
		fthd_release_buffer_ctx(dev_priv, ctx);
}

static int fthd_send_h2t_buffer(struct fthd_private *dev_priv, struct h2t_buf_ctx *ctx)
{
	u32 entry;
	int ret;

	pr_debug("sending buffer %p size %ld, ctx %p\n", ctx->vb, sizeof(ctx->dma_desc_list), ctx);
	ret = FTHD_S2_MEMCPY_TOIO(ctx->dma_desc_obj->offset,
				   &ctx->dma_desc_list,
				   sizeof(ctx->dma_desc_list));
	if (ret)
		return ret;
	ret = fthd_channel_ringbuf_send(dev_priv, dev_priv->channel_buf_h2t,
					ctx->dma_desc_obj->offset, 0x180, 0x30000000, &entry);

	if (ret) {
		dev_err(&dev_priv->pdev->dev, "%s: fthd_channel_ringbuf_send: %d\n", __func__, ret);
		return ret;
	}
	return fthd_channel_wait_ready(dev_priv, dev_priv->channel_buf_h2t, entry, 2000);
}

static void fthd_buffer_queue(struct vb2_buffer *vb)
{
	struct fthd_private *dev_priv = vb2_get_drv_priv(vb->vb2_queue);
	struct dma_descriptor_list *list;
	struct h2t_buf_ctx *ctx;
	unsigned long flags;
	bool send = false;

	pr_debug("vb = %p\n", vb);
	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	ctx = fthd_ctx_for_vb(dev_priv, vb);

	if (!ctx || ctx->state != BUF_ALLOC)
		goto out_unlock;

	if (!vb->vb2_queue->streaming) {
		ctx->state = BUF_DRV_QUEUED;
	} else {
		list = &ctx->dma_desc_list;
		list->field0 = 1;
		ctx->state = BUF_HW_QUEUED;
		wmb();
		pr_debug("%td: field0: %d, count %d, pool %d, addr0 0x%08x, addr1 0x%08x tag 0x%08llx vb = %p\n",
			 ctx - dev_priv->h2t_bufs, list->field0,
			 list->desc[0].count, list->desc[0].pool,
			 list->desc[0].addr0, list->desc[0].addr1,
			 list->desc[0].tag, ctx->vb);

		send = true;
	}
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

	if (send && fthd_send_h2t_buffer(dev_priv, ctx)) {
		fthd_mark_firmware_wedged(dev_priv);
		spin_lock_irqsave(&dev_priv->buffer_lock, flags);
		if (ctx->state == BUF_HW_QUEUED) {
			ctx->state = BUF_ALLOC;
			spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
			vb2_buffer_done(vb, VB2_BUF_STATE_ERROR);
			return;
		}
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
	}
	return;

out_unlock:
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
	vb2_buffer_done(vb, VB2_BUF_STATE_ERROR);
}

static int fthd_buffer_prepare(struct vb2_buffer *vb)
{
	struct fthd_private *dev_priv = vb2_get_drv_priv(vb->vb2_queue);
	struct sg_table *sgtable;
	struct h2t_buf_ctx *ctx = NULL;
	struct dma_descriptor_list *dma_list;
	unsigned long flags;
	u32 base;
	int i;
	int ret = 0;

	if (vb2_plane_size(vb, 0) < dev_priv->fmt.fmt.sizeimage)
		return -EINVAL;

	pr_debug("%p\n", vb);
	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	for (i = 0; i < FTHD_BUFFERS; i++) {
		if (dev_priv->h2t_bufs[i].state == BUF_FREE ||
		    (dev_priv->h2t_bufs[i].state == BUF_ALLOC && dev_priv->h2t_bufs[i].vb == vb)) {
			ctx = dev_priv->h2t_bufs + i;
			break;
		}
	}

	if (!ctx) {
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
		return -ENOBUFS;
	}

	if (ctx->state == BUF_FREE) {
		pr_debug("allocating new entry\n");
		ctx->vb = vb;
		ctx->state = BUF_ALLOC;
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

		ctx->dma_desc_obj = isp_mem_create(dev_priv, FTHD_MEM_BUFFER, 0x180);
		if (!ctx->dma_desc_obj) {
			ret = -ENOMEM;
			goto fail;
		}

		/* One mapping for the whole buffer, semi-planar included.  See
		 * the addr1 assignment below for why the chroma plane needs no
		 * mapping of its own. */
		sgtable = vb2_dma_sg_plane_desc(vb, 0);
		ctx->plane[0] = iommu_allocate_sgtable(dev_priv, sgtable);
		if (!ctx->plane[0]) {
			ret = -ENOMEM;
			goto fail;
		}
	} else {
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
	}

	vb2_set_plane_payload(vb, 0, dev_priv->fmt.fmt.sizeimage);

	dma_list = &ctx->dma_desc_list;
	memset(dma_list, 0, sizeof(*dma_list));

	dma_list->field0 = 1;
	dma_list->count = 1;
	dma_list->desc[0].count = 1;
	dma_list->desc[0].pool = 0x02;

	base = (ctx->plane[0]->offset << PAGE_SHIFT) |
		ctx->plane[0]->page_offset | 0xc0000000;
	dma_list->desc[0].addr0 = base;

	/* iommu_allocate_sgtable() walks the scatterlist into one contiguous
	 * run of S2 IOVA pages, so a semi-planar format's chroma plane is
	 * reachable as a plain byte offset from the start of that same mapping
	 * rather than needing a second one.  fthd_v4l2_adjust_format() sized
	 * the buffer for both planes, so this address is still inside it. */
	if (fthd_format_semiplanar(dev_priv->fmt.fmt.pixelformat))
		dma_list->desc[0].addr1 = base +
			dev_priv->fmt.fmt.bytesperline * dev_priv->fmt.fmt.height;

	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	ctx->tag = ++dev_priv->buffer_tag;
	if (!ctx->tag)
		ctx->tag = ++dev_priv->buffer_tag;
	dma_list->desc[0].tag = ctx->tag;
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
	return 0;

fail:
	fthd_buffer_cleanup(vb);
	return ret;
}

static void fthd_protocol_error(struct fthd_private *dev_priv)
{
	unsigned long flags;
	bool fatal = false;

	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	if (dev_priv->protocol_errors < FTHD_PROTOCOL_ERROR_LIMIT &&
	    ++dev_priv->protocol_errors == FTHD_PROTOCOL_ERROR_LIMIT)
		fatal = true;
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

	if (fatal) {
		dev_err(&dev_priv->pdev->dev,
			"too many invalid firmware buffer returns; failing the queue\n");
		fthd_mark_firmware_wedged(dev_priv);
	}
}

void fthd_buffer_return_handler(struct fthd_private *dev_priv, u32 offset,
				u32 size)
{
	struct dma_descriptor_list list;
	struct h2t_buf_ctx *ctx = NULL;
	struct vb2_buffer *vb = NULL;
	struct vb2_v4l2_buffer *vbuf;
	enum fthd_buffer_state invalid_state = BUF_FREE;
	bool deliver = true;
	unsigned long flags;
	int i;

	if (size && size < sizeof(list)) {
		dev_warn(&dev_priv->pdev->dev,
			 "short buffer return descriptor: %u bytes\n", size);
		fthd_protocol_error(dev_priv);
		return;
	}

	if (FTHD_S2_MEMCPY_FROMIO(&list, offset, sizeof(list))) {
		dev_warn_ratelimited(&dev_priv->pdev->dev,
				     "unreadable buffer return descriptor at %#x\n",
				     offset);
		fthd_protocol_error(dev_priv);
		return;
	}

	if (list.count != 1) {
		dev_warn_ratelimited(&dev_priv->pdev->dev,
				     "buffer return descriptor at %#x has %u entries\n",
				     offset, list.count);
		fthd_protocol_error(dev_priv);
		return;
	}

	/* Match on the opaque generation tag the firmware echoes back, which is
	 * the only field it is contractually required to return unchanged.
	 *
	 * Do NOT match on dma_desc_obj->offset: that assumes the address in the
	 * ring entry is the descriptor object we submitted, and on a MacBookAir7,2
	 * it is not - the lookup missed for every frame, the handler returned
	 * silently, and capture starved after the initial buffer set with no
	 * diagnostic at all.
	 *
	 * The tag is a generation counter, never a kernel pointer, so a hostile
	 * or confused firmware can at worst complete the wrong one of our own
	 * buffers - which is what the state check below is for. */
	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	for (i = 0; i < FTHD_BUFFERS; i++) {
		/* Tags start at 1, so zero means "never submitted" and must not
		 * match a zeroed descriptor. */
		if (dev_priv->h2t_bufs[i].tag &&
		    dev_priv->h2t_bufs[i].tag == list.desc[0].tag) {
			ctx = &dev_priv->h2t_bufs[i];
			break;
		}
	}

	if (!ctx) {
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
		dev_warn_ratelimited(&dev_priv->pdev->dev,
				     "buffer return at %#x carries unknown tag %#llx\n",
				     offset, list.desc[0].tag);
		fthd_protocol_error(dev_priv);
		return;
	}

	pr_debug("field0: %d, count %d, pool %d, addr0 0x%08x, addr1 0x%08x tag 0x%08llx vb = %p, ctx = %p\n",
		 list.field0, list.desc[0].count, list.desc[0].pool,
		 list.desc[0].addr0, list.desc[0].addr1,
		 list.desc[0].tag, ctx->vb, ctx);

	if ((ctx->state == BUF_HW_QUEUED || ctx->state == BUF_DRV_QUEUED) &&
	    ctx->vb) {
		vb = ctx->vb;
		dev_priv->protocol_errors = 0;

		/* Frame-rate division: deliver the first frame of every group of
		 * @fps_divisor and give the rest straight back.  The phase is
		 * only ever touched here and at STREAMON, both under this lock. */
		if (dev_priv->fps_divisor > 1) {
			deliver = dev_priv->frame_phase == 0;
			if (++dev_priv->frame_phase >= dev_priv->fps_divisor)
				dev_priv->frame_phase = 0;
		}

		/* A decimated buffer stays the driver's, for the requeue worker. */
		ctx->state = deliver ? BUF_ALLOC : BUF_DRV_QUEUED;
		ctx->requeue = !deliver;
	} else {
		invalid_state = ctx->state;
	}

	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
	if (!vb) {
		dev_warn_ratelimited(&dev_priv->pdev->dev,
				     "buffer return tag %#llx has invalid state %u\n",
				     list.desc[0].tag, invalid_state);
		fthd_protocol_error(dev_priv);
		return;
	}

	if (!deliver) {
		/* Decimated away.  The buffer never becomes visible to
		 * userspace: it stays owned by the driver and goes back to the
		 * ISP from the requeue worker.  The send cannot happen here -
		 * this runs inside fthd_irq_work(), and fthd_send_h2t_buffer()
		 * waits on the very channel whose completions that same work
		 * item is what processes. */
		schedule_work(&dev_priv->requeue_work);
		return;
	}

	vbuf = to_vb2_v4l2_buffer(vb);
	vbuf->sequence = dev_priv->sequence++;
	vbuf->vb2_buf.timestamp = ktime_get_ns();
	vbuf->field = V4L2_FIELD_NONE;
	vb2_buffer_done(vb, VB2_BUF_STATE_DONE);
}

/*
 * Hand back the frames fthd_buffer_return_handler() decided not to deliver.
 *
 * Runs in its own work item purely for context: the return handler cannot send
 * to the h2t channel itself without deadlocking against the IRQ work it runs
 * inside.  Everything else mirrors the streaming branch of fthd_buffer_queue().
 */
static void fthd_requeue_work(struct work_struct *work)
{
	struct fthd_private *dev_priv =
		container_of(work, struct fthd_private, requeue_work);
	unsigned long flags;
	int i;

	for (i = 0; i < FTHD_BUFFERS; i++) {
		struct h2t_buf_ctx *ctx = &dev_priv->h2t_bufs[i];
		bool send = false;

		spin_lock_irqsave(&dev_priv->buffer_lock, flags);
		/* channel_running going false means stop_streaming() or a
		 * suspend is taking the buffers back; leaving this one
		 * BUF_DRV_QUEUED is what lets fthd_return_all_buffers() find
		 * it. */
		if (ctx->requeue && ctx->state == BUF_DRV_QUEUED && ctx->vb &&
		    dev_priv->channel_running) {
			ctx->requeue = false;
			ctx->dma_desc_list.field0 = 1;
			ctx->state = BUF_HW_QUEUED;
			send = true;
		}
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

		if (!send)
			continue;

		if (fthd_send_h2t_buffer(dev_priv, ctx)) {
			fthd_mark_firmware_wedged(dev_priv);
			spin_lock_irqsave(&dev_priv->buffer_lock, flags);
			if (ctx->state == BUF_HW_QUEUED) {
				struct vb2_buffer *vb = ctx->vb;

				ctx->state = BUF_ALLOC;
				spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
				vb2_buffer_done(vb, VB2_BUF_STATE_ERROR);
				continue;
			}
			spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
		}
	}
}

static void fthd_return_all_buffers(struct fthd_private *dev_priv,
				    enum vb2_buffer_state state)
{
	struct vb2_buffer *buffers[FTHD_BUFFERS];
	unsigned long flags;
	int count = 0;
	int i;

	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	for (i = 0; i < FTHD_BUFFERS; i++) {
		struct h2t_buf_ctx *ctx = &dev_priv->h2t_bufs[i];

		if ((ctx->state == BUF_DRV_QUEUED ||
		     ctx->state == BUF_HW_QUEUED) && ctx->vb) {
			buffers[count++] = ctx->vb;
			ctx->state = BUF_ALLOC;
			ctx->requeue = false;
		}
	}
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

	for (i = 0; i < count; i++)
		vb2_buffer_done(buffers[i], state);
}

/*
 * Bring the ISP channel up and hand it every buffer already sitting in a
 * hardware slot.
 *
 * Shared by STREAMON and by the system-resume path, which has to redo exactly
 * this once the firmware is back.  Two things are deliberately left to the
 * caller.  The frame counter is not reset here, because a resume continues the
 * stream the application is already reading and must not restart its sequence
 * numbers.  And @require_buffers separates the two callers: vb2 guarantees at
 * least one queued buffer at STREAMON, so nothing to submit there means
 * something is wrong, while a resume can legitimately find every buffer sitting
 * in userspace.
 */
static int fthd_stream_start(struct fthd_private *dev_priv, bool require_buffers)
{
	struct h2t_buf_ctx *ctx;
	unsigned int submitted = 0;
	int i, ret;

	spin_lock_irq(&dev_priv->buffer_lock);
	dev_priv->protocol_errors = 0;
	spin_unlock_irq(&dev_priv->buffer_lock);

	if (READ_ONCE(dev_priv->removing)) {
		ret = -ENODEV;
		goto fail_buffers;
	}
	if (READ_ONCE(dev_priv->wedged)) {
		ret = -EIO;
		goto fail_buffers;
	}

	ret = fthd_start_channel(dev_priv, 0);
	if (ret) {
		/* The firmware command sequence may have failed after a partial start. */
		fthd_stop_channel(dev_priv, 0);
		fthd_return_all_buffers(dev_priv, VB2_BUF_STATE_QUEUED);
		return ret;
	}
	dev_priv->channel_running = true;

	/* Starting the channel resets the ISP, so push the control values down. */
	ret = v4l2_ctrl_handler_setup(&dev_priv->v4l2_ctrl_handler);
	if (ret)
		goto fail_channel;

	for (i = 0; i < FTHD_BUFFERS; i++) {
		unsigned long flags;
		bool submit = false;

		ctx = dev_priv->h2t_bufs + i;
		spin_lock_irqsave(&dev_priv->buffer_lock, flags);
		if (ctx->state == BUF_DRV_QUEUED) {
			ctx->state = BUF_HW_QUEUED;
			submit = true;
		}
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);
		if (!submit)
			continue;

		ret = fthd_send_h2t_buffer(dev_priv, ctx);
		if (ret) {
			fthd_mark_firmware_wedged(dev_priv);
			goto fail_channel;
		}
		submitted++;
	}
	if (!submitted && require_buffers) {
		ret = -ENOBUFS;
		goto fail_channel;
	}
	return 0;

fail_channel:
	dev_priv->channel_running = false;
	fthd_stop_channel(dev_priv, 0);
fail_buffers:
	fthd_return_all_buffers(dev_priv, VB2_BUF_STATE_QUEUED);
	return ret;
}

static int fthd_start_streaming(struct vb2_queue *vq, unsigned int count)
{
	struct fthd_private *dev_priv = vb2_get_drv_priv(vq);

	pr_debug("count = %d\n", count);
	dev_priv->sequence = 0;
	/* A new stream starts on a group boundary, so its first frame is always
	 * delivered whatever rate was selected. */
	dev_priv->frame_phase = 0;

	return fthd_stream_start(dev_priv, true);
}

static void fthd_stop_streaming(struct vb2_queue *vq)
{
	struct fthd_private *dev_priv = vb2_get_drv_priv(vq);
	int ret;

	/* A system suspend that arrived mid-stream already stopped the channel,
	 * and a resume that could not restart it errored the queue; the
	 * STREAMOFF that clears that error then lands here with nothing left to
	 * stop. */
	if (dev_priv->channel_running) {
		dev_priv->channel_running = false;

		ret = fthd_stop_channel(dev_priv, 0);
		if (ret)
			dev_warn(&dev_priv->pdev->dev,
				 "failed to stop firmware channel: %d\n", ret);
	}

	/* Must happen after channel_running is cleared and before the buffers
	 * are returned: a requeue worker that got past its state check would
	 * otherwise hand vb2's buffer back to the ISP just as vb2 reclaims it.
	 * The worker takes no lock this path holds. */
	cancel_work_sync(&dev_priv->requeue_work);

	/* stop_streaming must return every buffer owned by the driver.  Never
	 * wait without a timeout for firmware that has already failed a command. */
	fthd_return_all_buffers(dev_priv, VB2_BUF_STATE_ERROR);
}

/*
 * Give the hardware up for a system suspend that arrived with buffers
 * allocated - usually with an app streaming.  Unlike a runtime suspend this
 * cannot be refused: returning an error from the system sleep callback aborts
 * the whole transition and the machine stays awake, so the stream has to come
 * down under userspace instead.
 *
 * Everything the buffers own lives in ISP memory that fthd_pm_down() is about
 * to destroy, so it is all released here while the registers are still mapped.
 *
 * With @park set that is the *only* thing userspace loses.  The buffers vb2 has
 * handed to the driver are recorded and left owned by it - not returned, not
 * errored - so fthd_v4l2_resume_start() can rebuild their mappings, restart the
 * channel and let the application's feed simply continue.  Holding raw vb2
 * pointers across the sleep is safe because only userspace can free a buffer,
 * and it is frozen for the whole transition.
 *
 * @park is false on the shutdown path, where nothing will ever resume.  There
 * the buffers are returned with an error and the queue is marked, so an
 * application blocked in DQBUF or poll() gets -EIO instead of waiting for
 * frames that are not coming.  That is also the fallback the resume path takes
 * if it cannot get the stream going again: vb2 only re-runs buf_prepare() after
 * a STREAMOFF, so marking the queue is what tells an app it has to do one
 * before its STREAMON.
 *
 * Runs under ioctl_lock, with the hardware still powered: buffers can only be
 * allocated while /dev/videoN is open, and an open fd holds a runtime-PM
 * reference.
 */
void fthd_v4l2_suspend_stop(struct fthd_private *dev_priv, bool park)
{
	unsigned int parked = 0;
	unsigned long flags;
	int i;

	if (dev_priv->channel_running) {
		dev_priv->channel_running = false;
		if (fthd_stop_channel(dev_priv, 0))
			dev_warn(&dev_priv->pdev->dev,
				 "failed to stop firmware channel for suspend\n");
	}

	/* Same reason as in fthd_stop_streaming(): no decimated buffer may be
	 * sent to an ISP that is about to lose power, and none may still be in
	 * flight when the loop below detaches every slot. */
	cancel_work_sync(&dev_priv->requeue_work);

	dev_priv->parked_count = 0;
	dev_priv->parked_streaming = false;

	if (park) {
		/* Slot order, not queue order: which buffer the firmware fills
		 * first is its choice either way, and every one of these goes
		 * back to it before a single frame is produced. */
		spin_lock_irqsave(&dev_priv->buffer_lock, flags);
		for (i = 0; i < FTHD_BUFFERS; i++) {
			struct h2t_buf_ctx *ctx = &dev_priv->h2t_bufs[i];

			if ((ctx->state == BUF_DRV_QUEUED ||
			     ctx->state == BUF_HW_QUEUED) && ctx->vb) {
				dev_priv->parked_bufs[parked++] = ctx->vb;
				/* Detach the buffer from its slot under the
				 * same lock that records it, so a buffer return
				 * racing this suspend cannot also complete one
				 * the resume has already promised to resubmit.
				 * Such a return finds an unowned slot and is
				 * reported as the protocol error it is. */
				ctx->state = BUF_ALLOC;
				ctx->vb = NULL;
			}
		}
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

		dev_priv->parked_count = parked;
		dev_priv->parked_streaming = vb2_is_streaming(&dev_priv->vb2_queue);
	} else {
		fthd_return_all_buffers(dev_priv, VB2_BUF_STATE_ERROR);
	}

	for (i = 0; i < FTHD_BUFFERS; i++)
		fthd_release_buffer_ctx(dev_priv, &dev_priv->h2t_bufs[i]);

	if (!park)
		vb2_queue_error(&dev_priv->vb2_queue);
}

/*
 * Put back what fthd_v4l2_suspend_stop() parked, so an application that was
 * capturing when the lid closed keeps capturing when it opens - no -EIO, no
 * STREAMOFF/STREAMON dance, nothing for it to notice beyond the gap in
 * timestamps.
 *
 * The ISP has just been reloaded from scratch, so every buffer vb2 still
 * considers the driver's needs its descriptor and its S2 mapping built again.
 * fthd_buffer_prepare() is exactly that work and all the slots are free by
 * now, so each one lands where a fresh QBUF would put it; the channel then
 * comes back up and takes them, replaying the control values on the way.
 *
 * @powered says whether the force-resume actually brought the hardware back.
 * It does so exactly when something still held the camera open, which is also
 * the only way buffers can exist - so a false here means something is wrong,
 * not that the camera is merely idle.
 *
 * Runs under ioctl_lock from the system resume callback, with userspace still
 * frozen.  If any of it fails there is nothing better to do than what the
 * driver did before it learned to resume: hand the buffers back with an error
 * and mark the queue.
 */
void fthd_v4l2_resume_start(struct fthd_private *dev_priv, bool powered)
{
	unsigned int i = 0, parked = dev_priv->parked_count;
	unsigned long flags;
	int ret = 0;

	if (!parked && !dev_priv->parked_streaming)
		return;

	dev_priv->parked_count = 0;

	/* Nothing below may touch the hardware if it did not come back up - and
	 * the channel restart at the end would do so even with no buffers to
	 * restore. */
	if (!powered) {
		ret = -ENODEV;
		goto fail;
	}

	for (i = 0; i < parked; i++) {
		struct vb2_buffer *vb = dev_priv->parked_bufs[i];
		struct h2t_buf_ctx *ctx;

		ret = fthd_buffer_prepare(vb);
		if (ret)
			break;

		/* The state a QBUF before STREAMON leaves behind, which is what
		 * the submit loop in fthd_stream_start() looks for. */
		spin_lock_irqsave(&dev_priv->buffer_lock, flags);
		ctx = fthd_ctx_for_vb(dev_priv, vb);
		if (ctx && ctx->state == BUF_ALLOC)
			ctx->state = BUF_DRV_QUEUED;
		else
			ctx = NULL;
		spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

		if (!ctx) {
			/* Cannot happen - the prepare above just claimed a slot
			 * for this buffer.  Drop whatever it did claim so the
			 * error path below finds no slot owning this buffer and
			 * hands it back itself, rather than either path assuming
			 * the other did. */
			fthd_buffer_cleanup(vb);
			ret = -ENOBUFS;
			break;
		}
	}

	if (!ret && dev_priv->parked_streaming)
		ret = fthd_stream_start(dev_priv, false);

	if (!ret) {
		dev_priv->parked_streaming = false;
		return;
	}

fail:
	dev_priv->parked_streaming = false;
	dev_warn(&dev_priv->pdev->dev,
		 "could not resume capture (%d); failing the queue\n", ret);

	/* Buffers that never made it back into a slot are still the driver's as
	 * far as vb2 is concerned and have to be handed over explicitly.  The
	 * ones that did are reachable through their slots. */
	for (; i < parked; i++)
		vb2_buffer_done(dev_priv->parked_bufs[i], VB2_BUF_STATE_ERROR);

	fthd_return_all_buffers(dev_priv, VB2_BUF_STATE_ERROR);
	vb2_queue_error(&dev_priv->vb2_queue);
}

static const struct vb2_ops vb2_queue_ops = {
	.queue_setup            = fthd_buffer_queue_setup,
	.buf_prepare            = fthd_buffer_prepare,
	.buf_cleanup            = fthd_buffer_cleanup,
	.start_streaming        = fthd_start_streaming,
	.stop_streaming         = fthd_stop_streaming,
	.buf_queue              = fthd_buffer_queue,
#if LINUX_VERSION_CODE < KERNEL_VERSION(7, 0, 0)
	.wait_prepare           = vb2_ops_wait_prepare,
	.wait_finish            = vb2_ops_wait_finish,
#endif
};

/*
 * An open file descriptor is what keeps the camera powered: runtime PM parks
 * the ISP whenever nothing has /dev/videoN open, and the reference taken here
 * is what brings it back.  Held across the whole life of the fd rather than
 * just streaming, because every ioctl below talks to the firmware.
 */
static int fthd_v4l2_open(struct file *filp)
{
	struct fthd_private *dev_priv = video_drvdata(filp);
	int ret;

	mutex_lock(&dev_priv->ioctl_lock);
	if (READ_ONCE(dev_priv->removing)) {
		ret = -ENODEV;
		goto out_unlock;
	}

	ret = fthd_pm_get(dev_priv);
	if (ret)
		goto out_unlock;
	if (READ_ONCE(dev_priv->removing)) {
		fthd_pm_put(dev_priv);
		ret = -ENODEV;
		goto out_unlock;
	}

	ret = v4l2_fh_open(filp);
	if (ret)
		fthd_pm_put(dev_priv);

out_unlock:
	mutex_unlock(&dev_priv->ioctl_lock);
	return ret;
}

static int fthd_v4l2_release(struct file *filp)
{
	struct fthd_private *dev_priv = video_drvdata(filp);
	int ret;

	ret = vb2_fop_release(filp);
	fthd_pm_put(dev_priv);

	return ret;
}

static const struct v4l2_file_operations fthd_vdev_fops = {
	.owner          = THIS_MODULE,
	.open           = fthd_v4l2_open,

	.read		= vb2_fop_read,
	.release        = fthd_v4l2_release,
	.poll           = vb2_fop_poll,
	.mmap           = vb2_fop_mmap,
	.unlocked_ioctl = video_ioctl2
};

static int fthd_v4l2_ioctl_enum_input(struct file *filp, void *priv,
				      struct v4l2_input *input)
{
	if (input->index != 0)
		return -EINVAL;

	memset(input, 0, sizeof(*input));
	strscpy(input->name, "Camera", sizeof(input->name));
	input->type = V4L2_INPUT_TYPE_CAMERA;
	input->std = 0;

	return 0;
}

static int fthd_v4l2_ioctl_g_input(struct file *filp, void *priv, unsigned int *i)
{
	*i = 0;
	return 0;
}

static int fthd_v4l2_ioctl_s_input(struct file *filp, void *priv, unsigned int i)
{
	if (i != 0)
		return -EINVAL;
	return 0;
}

static int fthd_v4l2_ioctl_querycap(struct file *filp, void *priv,
				    struct v4l2_capability *cap)
{
	struct fthd_private *dev_priv = video_drvdata(filp);

	strscpy(cap->driver, "facetimehd", sizeof(cap->driver));
	strscpy(cap->card, "Apple Facetime HD", sizeof(cap->card));
	snprintf(cap->bus_info, sizeof(cap->bus_info), "PCI:%s",
		 pci_name(dev_priv->pdev));

	cap->device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_READWRITE |
			   V4L2_CAP_STREAMING;
	cap->capabilities = cap->device_caps | V4L2_CAP_DEVICE_CAPS;
	return 0;
}

/*
 * The ISP's output-format codes are NV12 0, YUYV 1, YVYU 2.  NV16 is absent
 * because no code produces it: code 0 was measured writing 4:2:0 on hardware.
 * YVYU is absent because code 2 writes invalid chroma (both U and V near 49,
 * rendering green and pink) rather than YUYV with the chroma swapped.
 */
static bool fthd_format_supported(u32 pixelformat)
{
	return pixelformat == V4L2_PIX_FMT_YUYV ||
	       pixelformat == V4L2_PIX_FMT_NV12;
}

static int fthd_v4l2_ioctl_enum_fmt_vid_cap(struct file *filp, void *priv,
				   struct v4l2_fmtdesc *fmt)
{
	char *desc = NULL;

	switch (fmt->index) {
	case 0:
		fmt->pixelformat = V4L2_PIX_FMT_NV12;
		desc = "NV12";
		break;
	case 1:
		fmt->pixelformat = V4L2_PIX_FMT_YUYV;
		desc = "YUYV";
		break;
	default:
		return -EINVAL;
	}

	fmt->type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	strscpy(fmt->description, desc, sizeof(fmt->description));

	return 0;
}

static int fthd_v4l2_adjust_format(struct fthd_private *dev_priv,
				   struct v4l2_pix_format *pix)
{

	/* Upper bound is the sensor's native resolution (e.g. 1280x720 on
	 * MacBookPro, 848x588 on the 12-inch MacBook); fall back to the generic
	 * ceiling if it hasn't been detected yet. */
	unsigned int max_w = dev_priv->sensor_width  ? : FTHD_MAX_WIDTH;
	unsigned int max_h = dev_priv->sensor_height ? : FTHD_MAX_HEIGHT;

	/* Coerce an unsupported request to the default rather than refusing it:
	 * TRY_FMT and S_FMT are adjusting calls, and the caller reads back what
	 * it got. */
	if (!fthd_format_supported(pix->pixelformat))
		pix->pixelformat = V4L2_PIX_FMT_NV12;

	if (pix->width < FTHD_MIN_WIDTH)
		pix->width = FTHD_MIN_WIDTH;
	if (pix->width > max_w)
		pix->width = max_w;
	if (pix->height < FTHD_MIN_HEIGHT)
		pix->height = FTHD_MIN_HEIGHT;
	if (pix->height > max_h)
		pix->height = max_h;

	pix->colorspace = V4L2_COLORSPACE_SRGB;
	pix->field = V4L2_FIELD_NONE;
	pix->width = ALIGN(pix->width, 8);
	if (pix->width > max_w)
		pix->width = round_down(max_w, 8);

	if (fthd_format_semiplanar(pix->pixelformat)) {
		/* Semi-planar 4:2:0: a width*height luma plane followed by an
		 * interleaved CbCr plane of half that height, so half the size.
		 * Both live in the one buffer, so bytesperline describes luma
		 * only while sizeimage covers the pair.  The halving is what
		 * hardware actually wrote - 360 chroma rows for a 720-row
		 * frame - not an assumption carried over from the format's
		 * name. */
		pix->bytesperline = pix->width;
		pix->sizeimage = pix->bytesperline * pix->height * 3 / 2;
	} else {
		pix->bytesperline = pix->width * 2;
		pix->sizeimage = pix->bytesperline * pix->height;
	}

	return 0;
}

static int fthd_v4l2_ioctl_try_fmt_vid_cap(struct file *filp, void *_priv,
					   struct v4l2_format *fmt)
{
	struct fthd_private *dev_priv = video_drvdata(filp);

	pr_debug("%s: %dx%d\n", __func__, fmt->fmt.pix.width, fmt->fmt.pix.height);

	if (fmt->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	return fthd_v4l2_adjust_format(dev_priv, &fmt->fmt.pix);
}

static int fthd_v4l2_ioctl_g_fmt_vid_cap(struct file *filp, void *priv,
					 struct v4l2_format *fmt)
{
	struct fthd_private *dev_priv = video_drvdata(filp);

	pr_debug("%s\n", __func__);
	fmt->type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	fmt->fmt.pix = dev_priv->fmt.fmt;

	return 0;
}

static int fthd_v4l2_ioctl_s_fmt_vid_cap(struct file *filp, void *priv,
					 struct v4l2_format *fmt)
{
	struct fthd_private *dev_priv = video_drvdata(filp);
	int ret;

	if (fmt->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	/* Existing buffers were allocated for the old size.  Reconfiguring the
	 * firmware while they remain mapped would let it DMA past those mappings. */
	if (vb2_is_busy(&dev_priv->vb2_queue))
		return -EBUSY;

	ret = fthd_v4l2_adjust_format(dev_priv, &fmt->fmt.pix);
	if (ret)
		return ret;

	pr_debug("%c%c%c%c\n", fmt->fmt.pix.pixelformat, fmt->fmt.pix.pixelformat >> 8,
		 fmt->fmt.pix.pixelformat >> 16, fmt->fmt.pix.pixelformat >> 24);

	dev_priv->fmt.fmt = fmt->fmt.pix;

	/* Re-derive the default crop for the new aspect ratio, or grow a chosen
	 * one that is now smaller than the output: the ISP must never be asked
	 * to upscale, and refusing the format instead would make S_FMT depend on
	 * the order the two were set in. */
	fthd_v4l2_refresh_crop(dev_priv);

	return 0;
}


static int fthd_v4l2_ioctl_g_parm(struct file *filp, void *priv,
		struct v4l2_streamparm *parm)
{
	struct fthd_private *dev_priv = video_drvdata(filp);

	/* Always the rate actually delivered: the sensor's fixed FTHD_FPS
	 * divided by the decimation in force.  A reported rate the stream does
	 * not match makes GStreamer's pipewiresrc compute negative frame
	 * durations and stall.  Expressed as divisor/FTHD_FPS so that rates
	 * like 7.5 fps stay exact. */
	struct v4l2_fract timeperframe = {
		.numerator = dev_priv->fps_divisor,
		.denominator = FTHD_FPS,
	};

	if (parm->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	parm->parm.capture.readbuffers = FTHD_BUFFERS;
	parm->parm.capture.capability = V4L2_CAP_TIMEPERFRAME;
	parm->parm.capture.timeperframe = timeperframe;
	return 0;
}

static int fthd_v4l2_ioctl_s_parm(struct file *filp, void *priv,
		struct v4l2_streamparm *parm)
{
	struct fthd_private *dev_priv = video_drvdata(filp);
	struct v4l2_fract *tpf = &parm->parm.capture.timeperframe;
	unsigned int divisor;
	unsigned long flags;

	if (parm->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	/* V4L2 spec: either field zero asks for the default rate. */
	if (!tpf->numerator || !tpf->denominator) {
		divisor = 1;
	} else {
		/* Round the requested interval to the nearest whole number of
		 * sensor frames.  64-bit because a caller may legitimately pass
		 * a large numerator to express a very slow rate. */
		u64 frames = (u64)tpf->numerator * FTHD_FPS +
			     tpf->denominator / 2;

		do_div(frames, tpf->denominator);
		if (frames < 1)
			frames = 1;
		if (frames > FTHD_MAX_FPS_DIVISOR)
			frames = FTHD_MAX_FPS_DIVISOR;
		divisor = frames;
	}

	/* Read by the buffer-return handler, which holds only this lock. */
	spin_lock_irqsave(&dev_priv->buffer_lock, flags);
	dev_priv->fps_divisor = divisor;
	dev_priv->frame_phase = 0;
	spin_unlock_irqrestore(&dev_priv->buffer_lock, flags);

	/* Report back what was actually selected, which is what distinguishes
	 * an accepted rate from a silently ignored one. */
	return fthd_v4l2_ioctl_g_parm(filp, priv, parm);
}

/*
 * The ISP crops a rectangle of the sensor array and scales it to the negotiated
 * format (see fthd_start_channel()).  Making that rectangle settable is digital
 * zoom and pan: the same output size taken from a smaller part of the array.
 *
 * The crop is never smaller than the current output size, so the scaler is only
 * ever asked to shrink - nothing here can confirm the ISP upscales.  And it is
 * only settable while the channel is down, because the rectangle is programmed
 * once during the channel-start sequence.
 */
static void fthd_v4l2_crop_bounds(struct fthd_private *dev_priv,
				  struct v4l2_rect *r)
{
	r->left = 0;
	r->top = 0;
	r->width  = dev_priv->sensor_width  ? : FTHD_MAX_WIDTH;
	r->height = dev_priv->sensor_height ? : FTHD_MAX_HEIGHT;
}

/*
 * The largest centred window with the output's aspect ratio, so a 4:3 format
 * on the 16:9 array is cropped at the sides rather than squashed.  Rounding the
 * width down to eight keeps it at least the (eight-aligned) output width.
 */
static void fthd_v4l2_default_crop(struct fthd_private *dev_priv,
				   struct v4l2_rect *r)
{
	unsigned int ow = dev_priv->fmt.fmt.width;
	unsigned int oh = dev_priv->fmt.fmt.height;
	unsigned int sw, sh;

	fthd_v4l2_crop_bounds(dev_priv, r);
	sw = r->width;
	sh = r->height;

	if (ow && oh) {
		if ((u64)ow * sh >= (u64)sw * oh)
			r->height = sw * oh / ow;
		else
			r->width = sh * ow / oh;
	}
	r->width = round_down(r->width, 8);
	r->left = (sw - r->width) / 2;
	r->top  = (sh - r->height) / 2;
}

static void fthd_v4l2_get_crop(struct fthd_private *dev_priv,
			       struct v4l2_rect *r)
{
	*r = dev_priv->fmt.crop;
}

/*
 * Fit @r inside the sensor array, at least as large as the output format, and
 * store it.  The firmware accepts a window that leaves the array and then
 * delivers no frames until it is reloaded, so the origin is clamped to keep the
 * whole rectangle on the sensor.  The width is a multiple of eight, which also
 * rules out the odd-width-at-odd-offset window that faults the sensor
 * interface.
 */
static void fthd_v4l2_set_crop(struct fthd_private *dev_priv,
			       struct v4l2_rect *r)
{
	unsigned int max_w = dev_priv->sensor_width  ? : FTHD_MAX_WIDTH;
	unsigned int max_h = dev_priv->sensor_height ? : FTHD_MAX_HEIGHT;
	unsigned int min_w = max(FTHD_MIN_WIDTH, dev_priv->fmt.fmt.width);
	unsigned int min_h = max(FTHD_MIN_HEIGHT, dev_priv->fmt.fmt.height);

	/* The output can never exceed the array, so neither can the floor. */
	min_w = min(min_w, max_w);
	min_h = min(min_h, max_h);

	r->width  = clamp_t(unsigned int, r->width,  min_w, max_w);
	r->height = clamp_t(unsigned int, r->height, min_h, max_h);

	r->width = ALIGN(r->width, 8);
	if (r->width > max_w)
		r->width = round_down(max_w, 8);

	/* left and top are signed in struct v4l2_rect. */
	if (r->left < 0)
		r->left = 0;
	if (r->top < 0)
		r->top = 0;

	r->left = round_down(min_t(unsigned int, r->left, max_w - r->width), 8);
	r->top  = min_t(unsigned int, r->top, max_h - r->height);

	dev_priv->fmt.crop = *r;
}

/*
 * Re-fit the crop after something it depends on changed - a new output format,
 * or the sensor geometry becoming known.  Until S_SELECTION sets one, the crop
 * follows the format's aspect ratio.
 */
void fthd_v4l2_refresh_crop(struct fthd_private *dev_priv)
{
	struct v4l2_rect r;

	if (dev_priv->fmt.crop_set)
		fthd_v4l2_get_crop(dev_priv, &r);
	else
		fthd_v4l2_default_crop(dev_priv, &r);

	fthd_v4l2_set_crop(dev_priv, &r);
}

static int fthd_v4l2_ioctl_g_selection(struct file *filp, void *priv,
		struct v4l2_selection *sel)
{
	struct fthd_private *dev_priv = video_drvdata(filp);

	if (sel->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
		fthd_v4l2_get_crop(dev_priv, &sel->r);
		return 0;
	case V4L2_SEL_TGT_CROP_DEFAULT:
		fthd_v4l2_default_crop(dev_priv, &sel->r);
		return 0;
	case V4L2_SEL_TGT_CROP_BOUNDS:
		fthd_v4l2_crop_bounds(dev_priv, &sel->r);
		return 0;
	default:
		return -EINVAL;
	}
}

static int fthd_v4l2_ioctl_s_selection(struct file *filp, void *priv,
		struct v4l2_selection *sel)
{
	struct fthd_private *dev_priv = video_drvdata(filp);
	struct v4l2_rect def;

	if (sel->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	if (sel->target != V4L2_SEL_TGT_CROP)
		return -EINVAL;

	/* The rectangle only reaches the firmware in the channel-start sequence,
	 * so accepting one now would silently do nothing until the next
	 * STREAMON.  Same reasoning as S_FMT refusing while buffers exist. */
	if (vb2_is_busy(&dev_priv->vb2_queue))
		return -EBUSY;

	/* V4L2_SEL_FLAG_GE/_LE ask for a rectangle no smaller/larger than the
	 * one given.  This driver rounds in both directions, so it cannot honour
	 * either promise and must say so rather than return a rectangle that
	 * breaks it. */
	if (sel->flags & (V4L2_SEL_FLAG_GE | V4L2_SEL_FLAG_LE))
		return -ERANGE;

	/* Setting the CROP_DEFAULT rectangle hands the crop back to the format,
	 * so it follows the aspect ratio of later S_FMT calls again. */
	fthd_v4l2_set_crop(dev_priv, &sel->r);
	fthd_v4l2_default_crop(dev_priv, &def);
	dev_priv->fmt.crop_set = memcmp(&sel->r, &def, sizeof(def)) != 0;
	return 0;
}

static int fthd_v4l2_ioctl_enum_framesizes(struct file *filp, void *priv,
		struct v4l2_frmsizeenum *sizes)
{
	struct fthd_private *dev_priv = video_drvdata(filp);

	if (sizes->index)
		return -EINVAL;

	if (!fthd_format_supported(sizes->pixel_format))
		return -EINVAL;

	/* The ISP scales, so every size TRY_FMT accepts has to be enumerated,
	 * not just the sensor's native one.  The bounds and the width step must
	 * match fthd_v4l2_adjust_format() exactly. */
	sizes->type = V4L2_FRMSIZE_TYPE_STEPWISE;
	sizes->stepwise.min_width  = FTHD_MIN_WIDTH;
	sizes->stepwise.max_width  = round_down(dev_priv->sensor_width ? : FTHD_MAX_WIDTH, 8);
	sizes->stepwise.step_width = 8;
	sizes->stepwise.min_height  = FTHD_MIN_HEIGHT;
	sizes->stepwise.max_height  = dev_priv->sensor_height ? : FTHD_MAX_HEIGHT;
	sizes->stepwise.step_height = 1;

	return 0;
}

static int fthd_v4l2_ioctl_enum_frameintervals(struct file *filp, void *priv,
		struct v4l2_frmivalenum *interval)
{
	struct fthd_private *dev_priv = video_drvdata(filp);
	unsigned int max_w = dev_priv->sensor_width  ? : FTHD_MAX_WIDTH;
	unsigned int max_h = dev_priv->sensor_height ? : FTHD_MAX_HEIGHT;

	pr_debug("%s\n", __func__);

	if (interval->index)
		return -EINVAL;

	/* Must agree with ENUM_FMT, or this advertises an interval for a format
	 * the device does not offer. */
	if (!fthd_format_supported(interval->pixel_format))
		return -EINVAL;

	if (interval->width & 7
	    || interval->width < FTHD_MIN_WIDTH
	    || interval->width > round_down(max_w, 8)
	    || interval->height < FTHD_MIN_HEIGHT
	    || interval->height > max_h)
		return -EINVAL;

	/* Stepwise, because the rates the driver can deliver are exactly the
	 * sensor rate divided by a whole number of frames: k/FTHD_FPS for k in
	 * 1..FTHD_MAX_FPS_DIVISOR.  A discrete list would either omit rates
	 * S_PARM accepts or advertise ones it cannot hit exactly. */
	interval->type = V4L2_FRMIVAL_TYPE_STEPWISE;
	interval->stepwise.min.numerator = 1;
	interval->stepwise.min.denominator = FTHD_FPS;
	interval->stepwise.max.numerator = FTHD_MAX_FPS_DIVISOR;
	interval->stepwise.max.denominator = FTHD_FPS;
	interval->stepwise.step.numerator = 1;
	interval->stepwise.step.denominator = FTHD_FPS;

	return 0;
}

static int fthd_v4l2_ioctl_subscribe_event(struct v4l2_fh *fh,
		const struct v4l2_event_subscription *sub)
{
	switch (sub->type) {
	case V4L2_EVENT_CTRL:
		return v4l2_ctrl_subscribe_event(fh, sub);
	}

	return -EINVAL;
}

static const struct v4l2_ioctl_ops fthd_ioctl_ops = {
	.vidioc_enum_input      = fthd_v4l2_ioctl_enum_input,
	.vidioc_g_input         = fthd_v4l2_ioctl_g_input,
	.vidioc_s_input         = fthd_v4l2_ioctl_s_input,
	.vidioc_enum_fmt_vid_cap = fthd_v4l2_ioctl_enum_fmt_vid_cap,
	.vidioc_try_fmt_vid_cap = fthd_v4l2_ioctl_try_fmt_vid_cap,

	.vidioc_g_fmt_vid_cap   = fthd_v4l2_ioctl_g_fmt_vid_cap,
	.vidioc_s_fmt_vid_cap   = fthd_v4l2_ioctl_s_fmt_vid_cap,
	.vidioc_querycap        = fthd_v4l2_ioctl_querycap,


        .vidioc_reqbufs         = vb2_ioctl_reqbufs,
	.vidioc_create_bufs     = vb2_ioctl_create_bufs,
	.vidioc_querybuf        = vb2_ioctl_querybuf,
	.vidioc_qbuf            = vb2_ioctl_qbuf,
	.vidioc_dqbuf           = vb2_ioctl_dqbuf,
	.vidioc_expbuf          = vb2_ioctl_expbuf,
	.vidioc_streamon        = vb2_ioctl_streamon,
	.vidioc_streamoff       = vb2_ioctl_streamoff,

	.vidioc_g_parm          = fthd_v4l2_ioctl_g_parm,
	.vidioc_s_parm          = fthd_v4l2_ioctl_s_parm,
	.vidioc_g_selection     = fthd_v4l2_ioctl_g_selection,
	.vidioc_s_selection     = fthd_v4l2_ioctl_s_selection,
	.vidioc_enum_framesizes = fthd_v4l2_ioctl_enum_framesizes,
	.vidioc_enum_frameintervals = fthd_v4l2_ioctl_enum_frameintervals,

	.vidioc_subscribe_event	= fthd_v4l2_ioctl_subscribe_event,
	.vidioc_unsubscribe_event = v4l2_event_unsubscribe,

	.vidioc_log_status      = v4l2_ctrl_log_status,
};

/*
 * Only FTHD_CID_AWB_CCT_ESTIMATE is volatile; every other control is answered
 * by the framework from its own cached value and never reaches this.
 *
 * No ioctl_lock here.  The control handler hangs off vdev->ctrl_handler and
 * vdev->lock *is* ioctl_lock, so video_ioctl2() has already taken it by the
 * time either control op runs - taking it again would deadlock.  That is also
 * what serialises this against the debugfs readbacks, which take it explicitly.
 */
static int fthd_g_volatile_ctrl(struct v4l2_ctrl *ctrl)
{
	struct fthd_private *dev_priv = container_of(ctrl->handler,
						     struct fthd_private,
						     v4l2_ctrl_handler);
	u32 cct;
	int ret;

	if (ctrl->id != FTHD_CID_AWB_CCT_ESTIMATE)
		return -EINVAL;

	/*
	 * Nothing to read from an idle ISP, and this must not be the thing that
	 * powers one up: the read is a diagnostic, not a reason to train DDR and
	 * re-upload firmware.  Leaving ctrl->val alone reports the last value
	 * sampled while streaming - zero if there has never been one - which is
	 * what keeps G_CTRL succeeding for v4l2-compliance and for any
	 * application that reads controls before STREAMON.
	 */
	if (!dev_priv->channel_running)
		return 0;

	ret = fthd_pm_get(dev_priv);
	if (ret)
		return ret;
	ret = fthd_isp_cmd_channel_awb_cct_get(dev_priv, 0, &cct);
	fthd_pm_put(dev_priv);
	if (ret)
		return ret;

	/* The firmware field is a u32 and the observed range is a few thousand;
	 * clamping keeps a nonsensical reading inside the advertised range
	 * rather than letting it surface as a negative kelvin. */
	ctrl->val = clamp_t(u32, cct, FTHD_AWB_CCT_MIN, FTHD_AWB_CCT_MAX);
	return 0;
}

static int fthd_s_ctrl(struct v4l2_ctrl *ctrl)
{
	struct fthd_private *dev_priv = container_of(ctrl->handler, struct fthd_private, v4l2_ctrl_handler);
	int ret;

	pr_debug("id = %x, val = %d\n", ctrl->id, ctrl->val);

	/* The ISP rejects these while the channel is down.  The control
	 * framework has already stored the new value, and
	 * fthd_start_streaming() replays the whole handler once the channel is
	 * up, so accepting it here is what makes a control set before
	 * STREAMON take effect rather than fail. */
	if (!dev_priv->channel_running)
		return 0;

	switch (ctrl->id) {
	case V4L2_CID_CONTRAST:
		ret = fthd_isp_cmd_channel_contrast_set(dev_priv, 0, ctrl->val);
		break;
	case V4L2_CID_BRIGHTNESS:
		ret = fthd_isp_cmd_channel_brightness_set(dev_priv, 0, ctrl->val);
		break;
	case V4L2_CID_SATURATION:
		ret = fthd_isp_cmd_channel_saturation_set(dev_priv, 0, ctrl->val);
		break;
	case V4L2_CID_HUE:
		ret = fthd_isp_cmd_channel_hue_set(dev_priv, 0, ctrl->val);
		break;
	case V4L2_CID_AUTO_WHITE_BALANCE:
		ret = fthd_isp_cmd_channel_awb(dev_priv, 0, ctrl->val);
		break;
	case V4L2_CID_POWER_LINE_FREQUENCY:
		ret = fthd_isp_cmd_channel_ae_flicker_freq_set(dev_priv, 0,
				ctrl->val == V4L2_CID_POWER_LINE_FREQUENCY_50HZ ? 50 :
				ctrl->val == V4L2_CID_POWER_LINE_FREQUENCY_60HZ ? 60 : 0);
		break;
	case V4L2_CID_EXPOSURE_AUTO:
		ret = fthd_isp_cmd_channel_ae(dev_priv, 0,
				ctrl->val == V4L2_EXPOSURE_AUTO);
		break;
	default:
		return -EINVAL;
	}

	pr_debug("ret = %d\n", ret);
	return ret;
}

static const struct v4l2_ctrl_ops fthd_ctrl_ops = {
	.g_volatile_ctrl = fthd_g_volatile_ctrl,
	.s_ctrl = fthd_s_ctrl,
};

/*
 * Read-only, so v4l2_ctrl_handler_setup() skips it and no firmware SET is ever
 * replayed at STREAMON or after a runtime resume.  That is the structural
 * reason this control is safe to register while the manual AWB setter, whose
 * second payload word is still unidentified, is not.
 */
static const struct v4l2_ctrl_config fthd_ctrl_awb_cct_estimate = {
	.ops	= &fthd_ctrl_ops,
	.id	= FTHD_CID_AWB_CCT_ESTIMATE,
	.name	= "AWB CCT Estimate",
	.type	= V4L2_CTRL_TYPE_INTEGER,
	.min	= FTHD_AWB_CCT_MIN,
	.max	= FTHD_AWB_CCT_MAX,
	.step	= 1,
	.def	= FTHD_AWB_CCT_MIN,
	.flags	= V4L2_CTRL_FLAG_READ_ONLY | V4L2_CTRL_FLAG_VOLATILE,
};

static void fthd_video_device_release(struct video_device *vdev)
{
	struct fthd_private *dev_priv = video_get_drvdata(vdev);

	video_device_release(vdev);
	fthd_put(dev_priv);
}

int fthd_v4l2_register(struct fthd_private *dev_priv)
{
	struct v4l2_device *v4l2_dev = &dev_priv->v4l2_dev;
	struct video_device *vdev;
	struct vb2_queue *q;
	int ret;

	/* Before anything that can fail: the stop paths call
	 * cancel_work_sync() on this unconditionally. */
	INIT_WORK(&dev_priv->requeue_work, fthd_requeue_work);

	/* Full rate until S_PARM asks for less. */
	dev_priv->fps_divisor = 1;
	dev_priv->frame_phase = 0;

	ret = v4l2_device_register(&dev_priv->pdev->dev, v4l2_dev);
	if (ret) {
		dev_err(&dev_priv->pdev->dev, "v4l2_device_register: %d\n", ret);
		return ret;
	}

	vdev = video_device_alloc();
	if (!vdev) {
		ret = -ENOMEM;
		goto fail;
	}
	/* The video_device can outlive PCI unbind while an fd remains open. */
	if (WARN_ON_ONCE(!fthd_get(dev_priv))) {
		video_device_release(vdev);
		ret = -ENODEV;
		goto fail;
	}
	vdev->release = fthd_video_device_release;
	dev_priv->videodev = vdev;

	q = &dev_priv->vb2_queue;
	q->type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	q->io_modes = VB2_MMAP | VB2_USERPTR | VB2_DMABUF | VB2_READ;
	q->drv_priv = dev_priv;
	q->ops = &vb2_queue_ops;
	q->mem_ops = &vb2_dma_sg_memops;
	q->timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC;
	q->dev = &dev_priv->pdev->dev;
#if LINUX_VERSION_CODE < KERNEL_VERSION(6,8,0)
	q->min_buffers_needed = 1;
#else
	q->min_queued_buffers = 1;
#endif
	q->lock = &dev_priv->ioctl_lock;

	ret = vb2_queue_init(q);
	if (ret)
		goto fail_vdev_alloc;

	v4l2_ctrl_handler_init(&dev_priv->v4l2_ctrl_handler, 8);
	v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			  V4L2_CID_BRIGHTNESS, 0, 0xff, 1, 0x80);
	v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			  V4L2_CID_CONTRAST, 0, 0xff, 1, 0x80);
	v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			  V4L2_CID_SATURATION, 0, 0xff, 1, 0x80);
	v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			  V4L2_CID_HUE, 0, 0xff, 1, 0x80);
	v4l2_ctrl_new_std(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			  V4L2_CID_AUTO_WHITE_BALANCE, 0, 1, 1, 1);
	/* Anti-banding.  Defaults to disabled so the ISP keeps the behaviour it
	 * has always had unless the user asks for their mains frequency. */
	v4l2_ctrl_new_std_menu(&dev_priv->v4l2_ctrl_handler, &fthd_ctrl_ops,
			       V4L2_CID_POWER_LINE_FREQUENCY,
			       V4L2_CID_POWER_LINE_FREQUENCY_60HZ, 0,
			       V4L2_CID_POWER_LINE_FREQUENCY_DISABLED);
	v4l2_ctrl_new_std_menu(&dev_priv->v4l2_ctrl_handler,
			       &fthd_ctrl_ops, V4L2_CID_EXPOSURE_AUTO,
			       V4L2_EXPOSURE_MANUAL, 0,
			       V4L2_EXPOSURE_AUTO);
	/* Read-only: registering it adds a GET the application can ask for and
	 * no SET the framework can replay. */
	v4l2_ctrl_new_custom(&dev_priv->v4l2_ctrl_handler,
			     &fthd_ctrl_awb_cct_estimate, NULL);

	if (dev_priv->v4l2_ctrl_handler.error) {
		dev_err(&dev_priv->pdev->dev, "failed to setup control handlers\n");
		ret = dev_priv->v4l2_ctrl_handler.error;
		v4l2_ctrl_handler_free(&dev_priv->v4l2_ctrl_handler);
		goto fail_queue;
	}

	vdev->v4l2_dev = v4l2_dev;
	strscpy(vdev->name, "Apple Facetime HD", sizeof(vdev->name));
	vdev->vfl_dir = VFL_DIR_RX;
	vdev->lock = &dev_priv->ioctl_lock;
	vdev->fops = &fthd_vdev_fops;
	vdev->ioctl_ops = &fthd_ioctl_ops;
	vdev->queue = q;
	vdev->ctrl_handler = &dev_priv->v4l2_ctrl_handler;
	vdev->device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_READWRITE |
			    V4L2_CAP_STREAMING;
	video_set_drvdata(vdev, dev_priv);

	/* Initialise every field visible through G_FMT before publishing the
	 * device node: userspace may open it as soon as registration succeeds. */
	dev_priv->fmt.fmt.width = dev_priv->sensor_width ? : FTHD_MAX_WIDTH;
	dev_priv->fmt.fmt.height = dev_priv->sensor_height ? : FTHD_MAX_HEIGHT;
	dev_priv->fmt.fmt.pixelformat = V4L2_PIX_FMT_NV12;
	fthd_v4l2_adjust_format(dev_priv, &dev_priv->fmt.fmt);
	/* After the format, because the crop's lower bound is the output size.
	 * G_SELECTION is answerable from the first open either way; the channel
	 * start re-fits this once the real sensor geometry is known. */
	fthd_v4l2_refresh_crop(dev_priv);

	ret = video_register_device(vdev, VFL_TYPE_VIDEO, -1);
	if (ret) {
		vdev->release(vdev);
		vdev = NULL;
		dev_priv->videodev = NULL;
		goto fail_ctrl;
	}
	WRITE_ONCE(dev_priv->v4l2_registered, true);

	return 0;
fail_ctrl:
	v4l2_ctrl_handler_free(&dev_priv->v4l2_ctrl_handler);
fail_queue:
	vb2_queue_release(q);
fail_vdev_alloc:
	if (vdev)
		vdev->release(vdev);
fail:
	dev_priv->videodev = NULL;
	v4l2_device_unregister(&dev_priv->v4l2_dev);
	return ret;
}

void fthd_v4l2_unregister(struct fthd_private *dev_priv)
{
	struct video_device *vdev = dev_priv->videodev;

	if (!vdev)
		return;

	WRITE_ONCE(dev_priv->v4l2_registered, false);
	v4l2_device_disconnect(&dev_priv->v4l2_dev);
	vb2_video_unregister_device(vdev);
	dev_priv->videodev = NULL;
	v4l2_ctrl_handler_free(&dev_priv->v4l2_ctrl_handler);
	v4l2_device_unregister(&dev_priv->v4l2_dev);
}
