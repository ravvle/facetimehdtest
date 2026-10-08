/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * FacetimeHD camera driver
 *
 * Copyright (C) 2014 Patrik Jakobsson (patrik.r.jakobsson@gmail.com)
 *
 */

#ifndef _FTHD_DRV_H
#define _FTHD_DRV_H

#include <linux/pci.h>
#include <linux/kref.h>
#include <linux/spinlock.h>
#include <linux/wait.h>
#include <linux/mutex.h>
#include <linux/pm_runtime.h>
#include <linux/version.h>
#include <media/videobuf2-dma-sg.h>
#include <media/v4l2-device.h>
#include <media/v4l2-ctrls.h>
#include "fthd_reg.h"
#include "fthd_ringbuf.h"
#include "fthd_buffer.h"
#include "fthd_v4l2.h"

#define FTHD_PCI_S2_IO  0
#define FTHD_PCI_S2_MEM 2
#define FTHD_PCI_ISP_IO 4

#define FTHD_BUFFERS 8

enum FW_CHAN_TYPE {
	FW_CHAN_TYPE_OUT=0,
	FW_CHAN_TYPE_IN=1,
	FW_CHAN_TYPE_UNI_IN=2,
};

struct fw_channel {
	u32 offset;
	u32 size;
	u32 source;
	u32 type;
	struct fthd_ringbuf ringbuf;
	spinlock_t lock;
	/* waitqueue for signaling completion */
	wait_queue_head_t wq;
	char *name;
};

struct fthd_private {
	struct pci_dev *pdev;
	unsigned int dma_mask;

	struct v4l2_device v4l2_dev;
	struct video_device *videodev;
	struct mutex ioctl_lock;
	struct kref ref;
	bool removing;
	bool v4l2_registered;
	/* lock for synchronizing with irq/workqueue */
	spinlock_t io_lock;
	spinlock_t buffer_lock;

	/* Mapped PCI resources */
	void __iomem *s2_io;
	u32 s2_io_len;

	void __iomem *s2_mem;
	u32 s2_mem_len;

	void __iomem *isp_io;
	u32 isp_io_len;

	struct work_struct irq_work;

	/* Hardware info */
	u32 core_clk;
	u32 ddr_model;
	u32 ddr_speed;
	u32 vdl_step_size;

	u32 ddr_phy_regs[DDR_PHY_NUM_REG];

	/* Root resource for memory management */
	struct resource *mem;
	struct mutex mem_lock;
	struct list_head mem_objects;
	/* Resource for managing IO mmu slots */
	struct resource *iommu;
	/* ISP memory objects */
	struct isp_mem_obj *firmware;
	struct isp_mem_obj *set_file;
	struct isp_mem_obj *ipc_queue;
	struct isp_mem_obj *heap;

	/* Firmware channels */
	int num_channels;
	struct fw_channel **channels;
	struct fw_channel *channel_terminal;
	struct fw_channel *channel_io;
	struct fw_channel *channel_debug;
	struct fw_channel *channel_buf_h2t;
	struct fw_channel *channel_buf_t2h;
	struct fw_channel *channel_shared_malloc;
	struct fw_channel *channel_io_t2h;

	/* camera config */
	int sensor_count;
	int sensor_id0;
	int sensor_id1;
	/* Native sensor resolution, read from the firmware's per-channel camera
	 * config. MacBookPro sensors report 1280x720; the 12-inch MacBook
	 * (MacBook8,1, sensor 1675) reports 848x588. 0 until detected. */
	unsigned int sensor_width;
	unsigned int sensor_height;

	struct fthd_fmt fmt;

	struct vb2_queue vb2_queue;
	struct h2t_buf_ctx h2t_bufs[FTHD_BUFFERS];
	unsigned int protocol_errors;

	/* The buffers vb2 had handed to the driver when a system suspend
	 * arrived, and whether the queue was streaming at the time. The resume
	 * callback uses them to rebuild the ISP-side mappings the power cycle
	 * destroyed and put the stream back on the air, so that an application
	 * capturing across a suspend never sees an error. Only touched under
	 * ioctl_lock, and only between fthd_v4l2_suspend_stop() and
	 * fthd_v4l2_resume_start(); userspace is frozen for that whole window,
	 * so the buffers cannot be freed under them. */
	struct vb2_buffer *parked_bufs[FTHD_BUFFERS];
	unsigned int parked_count;
	bool parked_streaming;

	struct v4l2_ctrl_handler v4l2_ctrl_handler;
	/* True between a successful fthd_start_channel() and fthd_stop_channel().
	 * The ISP only accepts the image-quality commands while the channel is
	 * running, so s_ctrl consults this rather than failing when it isn't. */
	bool channel_running;
	/* Frame-rate division.  The sensor delivers a fixed rate and the driver
	 * passes on one frame in @fps_divisor of it, handing the rest straight
	 * back to the ISP from @requeue_work; @frame_phase counts within the
	 * current group.  Both are read and written only under buffer_lock. */
	unsigned int fps_divisor;
	/* EXPERIMENT: S_PARM programs the ISP AE frame-rate window instead of
	 * decimating.  Q8.8 fps, as the firmware takes it. */
	u32 ae_frame_rate;
	bool exposure_auto_priority;
	unsigned int frame_phase;
	struct work_struct requeue_work;
	unsigned int sequence;
	u64 buffer_tag;
	/* Serialises the hardware up/down transitions and @suspended. Runtime
	 * callbacks take only this lock; paths that also shut userspace out take
	 * ioctl_lock first, then pm_lock. */
	struct mutex pm_lock;
	bool suspended;
	/* Set across a system-sleep transition.  The system suspend callback
	 * deliberately invalidates allocated vb2 buffers before asking the
	 * runtime-PM core to force the hardware down, so runtime suspend must not
	 * reject that particular transition merely because vb2 is still busy. */
	bool system_suspending;
	/* Set when firmware stops answering or violates the streaming protocol,
	 * so commands fail fast and VB2 waiters wake with an error. Cleared in
	 * fthd_pm_down(), whose teardown reclaims whatever the wedge left
	 * unfreed; the next open() reloads firmware via fthd_pm_up(). */
	bool wedged;
	struct dentry *debugfs;
};

bool fthd_get(struct fthd_private *dev_priv);
void fthd_put(struct fthd_private *dev_priv);
void fthd_mark_firmware_wedged(struct fthd_private *dev_priv);

/* Bring the camera out of runtime suspend and hold it there.  Returns 0 with a
 * reference held, or a negative error with none.  Not usable from atomic
 * context, and not from anything holding pm_lock. */
static inline int fthd_pm_get(struct fthd_private *dev_priv)
{
	return pm_runtime_resume_and_get(&dev_priv->pdev->dev);
}

/* Drop the reference taken by fthd_pm_get() and restart the autosuspend
 * timer. */
static inline void fthd_pm_put(struct fthd_private *dev_priv)
{
	if (READ_ONCE(dev_priv->removing)) {
		pm_runtime_put_noidle(&dev_priv->pdev->dev);
		return;
	}
#if LINUX_VERSION_CODE < KERNEL_VERSION(6,17,0)
	/* Folded into pm_runtime_put_autosuspend() in 6.17, and removed
	 * outright once the tree-wide conversion finished. */
	pm_runtime_mark_last_busy(&dev_priv->pdev->dev);
#endif
	pm_runtime_put_autosuspend(&dev_priv->pdev->dev);
}

#endif
