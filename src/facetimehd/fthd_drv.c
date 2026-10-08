/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * FacetimeHD camera driver
 *
 * Copyright (C) 2014 Patrik Jakobsson (patrik.r.jakobsson@gmail.com)
 *
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/version.h>
#include <linux/io.h>
#include <linux/interrupt.h>
#include <linux/pm.h>
#include <linux/pm_runtime.h>
#include <linux/workqueue.h>
#include <linux/spinlock.h>
#include <linux/videodev2.h>
#include "fthd_drv.h"
#include "fthd_hw.h"
#include "fthd_isp.h"
#include "fthd_ringbuf.h"
#include "fthd_buffer.h"
#include "fthd_v4l2.h"
#include "fthd_debugfs.h"

/* Powering the ISP back up means re-training DDR and re-uploading the firmware
 * image, which is not cheap.  Idle for this long before doing it. */
#define FTHD_AUTOSUSPEND_DELAY_MS 5000
#define FTHD_PCI_BAR_MASK (BIT(FTHD_PCI_S2_IO) | BIT(FTHD_PCI_S2_MEM) | \
			   BIT(FTHD_PCI_ISP_IO))

static bool runtime_pm;
module_param(runtime_pm, bool, 0444);
MODULE_PARM_DESC(runtime_pm,
		 "Power the camera down while nothing has it open (default: 0). "
		 "Enable only after validating suspend/resume on this machine.");

static void fthd_pm_down(struct fthd_private *dev_priv);

static void fthd_release(struct kref *ref)
{
	struct fthd_private *dev_priv = container_of(ref, struct fthd_private,
						     ref);

	kfree(dev_priv);
}

bool fthd_get(struct fthd_private *dev_priv)
{
	return kref_get_unless_zero(&dev_priv->ref);
}

void fthd_put(struct fthd_private *dev_priv)
{
	kref_put(&dev_priv->ref, fthd_release);
}

void fthd_mark_firmware_wedged(struct fthd_private *dev_priv)
{
	WRITE_ONCE(dev_priv->wedged, true);
	if (READ_ONCE(dev_priv->v4l2_registered))
		vb2_queue_error(&dev_priv->vb2_queue);
}

static void fthd_pci_release_mem(struct fthd_private *dev_priv)
{
	if (dev_priv->s2_io) {
		pci_iounmap(dev_priv->pdev, dev_priv->s2_io);
		dev_priv->s2_io = NULL;
	}
	if (dev_priv->s2_mem) {
		pci_iounmap(dev_priv->pdev, dev_priv->s2_mem);
		dev_priv->s2_mem = NULL;
	}
	if (dev_priv->isp_io) {
		pci_iounmap(dev_priv->pdev, dev_priv->isp_io);
		dev_priv->isp_io = NULL;
	}

	pci_release_selected_regions(dev_priv->pdev, FTHD_PCI_BAR_MASK);
}

static int fthd_pci_reserve_mem(struct fthd_private *dev_priv)
{
	unsigned long len;
	int ret;

	ret = pci_request_selected_regions(dev_priv->pdev, FTHD_PCI_BAR_MASK,
					   KBUILD_MODNAME);
	if (ret) {
		dev_err(&dev_priv->pdev->dev, "Failed to request PCI BARs\n");
		return ret;
	}

	/* S2 IO */
	len = pci_resource_len(dev_priv->pdev, FTHD_PCI_S2_IO);
	dev_priv->s2_io = pci_iomap(dev_priv->pdev, FTHD_PCI_S2_IO, 0);
	dev_priv->s2_io_len = len;

	/* S2 MEM */
	len = pci_resource_len(dev_priv->pdev, FTHD_PCI_S2_MEM);
	dev_priv->s2_mem = pci_iomap(dev_priv->pdev, FTHD_PCI_S2_MEM, 0);
	dev_priv->s2_mem_len = len;

	/* ISP IO */
	len = pci_resource_len(dev_priv->pdev, FTHD_PCI_ISP_IO);
	dev_priv->isp_io = pci_iomap(dev_priv->pdev, FTHD_PCI_ISP_IO, 0);
	dev_priv->isp_io_len = len;
	if (!dev_priv->s2_io || !dev_priv->s2_mem || !dev_priv->isp_io) {
		dev_err(&dev_priv->pdev->dev, "Failed to map PCI BARs\n");
		fthd_pci_release_mem(dev_priv);
		return -ENOMEM;
	}

	pr_debug("Allocated S2 regs (BAR %d). %u bytes at 0x%p\n",
		 FTHD_PCI_S2_IO, dev_priv->s2_io_len, dev_priv->s2_io);

	pr_debug("Allocated S2 mem (BAR %d). %u bytes at 0x%p\n",
		 FTHD_PCI_S2_MEM, dev_priv->s2_mem_len, dev_priv->s2_mem);

	pr_debug("Allocated ISP regs (BAR %d). %u bytes at 0x%p\n",
		 FTHD_PCI_ISP_IO, dev_priv->isp_io_len, dev_priv->isp_io);

	return 0;
}

static void sharedmalloc_handler(struct fthd_private *dev_priv,
				 struct fw_channel *chan,
				 u32 entry)
{
	u32 request_size, response_size, address;
	struct isp_mem_obj *obj;
	u8 header[64] = { 0 };
	int ret;

	request_size = FTHD_S2_MEM_READ(entry + FTHD_RINGBUF_REQUEST_SIZE);
	response_size = FTHD_S2_MEM_READ(entry + FTHD_RINGBUF_RESPONSE_SIZE);
	address = FTHD_S2_MEM_READ(entry + FTHD_RINGBUF_ADDRESS_FLAGS) & ~ 3;

	if (address) {
		pr_debug("Firmware wants to free memory at %08x\n", address);
		if (address < sizeof(header) ||
		    isp_mem_destroy_offset(dev_priv, address - sizeof(header),
					   FTHD_MEM_SHAREDMALLOC))
			dev_warn(&dev_priv->pdev->dev,
				 "Firmware requested invalid shared-memory free at %#x\n",
				 address);

		ret = fthd_channel_ringbuf_send(dev_priv, chan, 0, 0, 0, NULL);
		if (ret)
			dev_err(&dev_priv->pdev->dev, "%s: fthd_channel_ringbuf_send: %d\n", __func__, ret);
	} else {
		if (dev_priv->s2_mem_len < sizeof(header) || !request_size ||
		    request_size > dev_priv->s2_mem_len - sizeof(header))
			return;
		obj = isp_mem_create(dev_priv, FTHD_MEM_SHAREDMALLOC, request_size + 64);
		if (!obj)
			return;

		pr_debug("Firmware allocated %d bytes at %08lx (tag %c%c%c%c)\n", request_size, obj->offset,
			 response_size >> 24,response_size >> 16,
			 response_size >> 8, response_size);
		ret = FTHD_S2_MEMCPY_TOIO(obj->offset, header, sizeof(header));
		if (ret) {
			isp_mem_destroy(obj);
			return;
		}
		ret = fthd_channel_ringbuf_send(dev_priv, chan, obj->offset + 64, 0, 0, NULL);
		if (ret) {
			dev_err(&dev_priv->pdev->dev, "%s: fthd_channel_ringbuf_send: %d\n", __func__, ret);
			isp_mem_destroy(obj);
		}

	}

}


static void terminal_handler(struct fthd_private *dev_priv,
				 struct fw_channel *chan,
				 u32 entry)
{
	u32 request_size, address;
	char buf[512];

	request_size = FTHD_S2_MEM_READ(entry + FTHD_RINGBUF_REQUEST_SIZE);
	address = FTHD_S2_MEM_READ(entry + FTHD_RINGBUF_ADDRESS_FLAGS) & ~ 3;

	if (!address || !request_size)
		return;

	if (request_size > 512)
		request_size = 512;
	if (FTHD_S2_MEMCPY_FROMIO(buf, address, request_size))
		return;
	/* The firmware's own console. Interesting when debugging the ISP,
	 * noise the rest of the time - and it arrives per firmware message,
	 * so at dev_info it is the single largest contributor to the log
	 * volume this driver produces while streaming. */
	dev_dbg(&dev_priv->pdev->dev, "FWMSG: %.*s", request_size, buf);
}

static void buf_t2h_handler(struct fthd_private *dev_priv,
			    struct fw_channel *chan,
			    u32 entry)
{
	u32 request_size, response_size, address;
	int ret;
	request_size = FTHD_S2_MEM_READ(entry + FTHD_RINGBUF_REQUEST_SIZE);
	response_size = FTHD_S2_MEM_READ(entry + FTHD_RINGBUF_RESPONSE_SIZE);
	address = FTHD_S2_MEM_READ(entry + FTHD_RINGBUF_ADDRESS_FLAGS);

	if (address & 1)
		return;


	fthd_buffer_return_handler(dev_priv, address & ~3, request_size);
	ret = fthd_channel_ringbuf_send(dev_priv, chan, (response_size & 0x10000000) ? address : 0,
					0, 0x80000000, NULL);
	if (ret)
		dev_err(&dev_priv->pdev->dev, "%s: fthd_channel_ringbuf_send: %d\n", __func__, ret);

}

static void io_t2h_handler(struct fthd_private *dev_priv,
				 struct fw_channel *chan,
				 u32 entry)
{
	int ret = fthd_channel_ringbuf_send(dev_priv, chan, 0, 0, 0, NULL);
	if (ret)
		dev_err(&dev_priv->pdev->dev, "%s: fthd_channel_ringbuf_send: %d\n", __func__, ret);

}

static void fthd_handle_irq(struct fthd_private *dev_priv, struct fw_channel *chan)
{
	u32 entry;
	int handled, ret;

	if (chan == dev_priv->channel_io) {
		pr_debug("IO channel ready\n");
		wake_up(&chan->wq);
		return;
	}

	if (chan == dev_priv->channel_buf_h2t) {
		pr_debug("H2T channel ready\n");
		wake_up(&chan->wq);
		return;
	}

	if (chan == dev_priv->channel_debug) {
		pr_debug("DEBUG channel ready\n");
		wake_up(&chan->wq);
		return;
	}

	/* A corrupt or wedged producer must not keep the global workqueue busy
	 * forever.  There cannot be more live entries than the ring contains. */
	for (handled = 0; handled < chan->size; handled++) {
		entry = fthd_channel_ringbuf_receive(dev_priv, chan);
		if (entry == (u32)-1)
			break;
		pr_debug("channel %s: message available, address %08x\n", chan->name, FTHD_S2_MEM_READ(entry + FTHD_RINGBUF_ADDRESS_FLAGS));
		if (chan == dev_priv->channel_shared_malloc) {
			sharedmalloc_handler(dev_priv, chan, entry);
		} else if (chan == dev_priv->channel_terminal) {
			terminal_handler(dev_priv, chan, entry);
			ret = fthd_channel_ringbuf_send(dev_priv, chan, 0, 0, 0, NULL);
			if (ret)
				dev_err(&dev_priv->pdev->dev, "%s: fthd_channel_ringbuf_send: %d\n", __func__, ret);
		} else if (chan == dev_priv->channel_buf_t2h) {
			buf_t2h_handler(dev_priv, chan, entry);
		} else if (chan == dev_priv->channel_io_t2h) {
			io_t2h_handler(dev_priv, chan, entry);
		}
	}
	if (handled == chan->size)
		dev_warn_ratelimited(&dev_priv->pdev->dev,
				     "channel %s did not drain\n", chan->name);
}

static void fthd_irq_uninstall(struct fthd_private *dev_priv)
{
	free_irq(pci_irq_vector(dev_priv->pdev, 0), dev_priv);
}

static void fthd_irq_work(struct work_struct *work)
{
	struct fthd_private *dev_priv = container_of(work, struct fthd_private, irq_work);
	struct fw_channel *chan;

	u32 pending;
	int i, loops;

	for (loops = 0; loops < 500; loops++) {
		spin_lock_irq(&dev_priv->io_lock);
		pending = FTHD_ISP_REG_READ(ISP_IRQ_STATUS);
		spin_unlock_irq(&dev_priv->io_lock);

		if (!(pending & 0xf0))
			break;

		pci_write_config_dword(dev_priv->pdev, 0x94, 0);
		spin_lock_irq(&dev_priv->io_lock);
		FTHD_ISP_REG_WRITE(pending, ISP_IRQ_CLEAR);
		spin_unlock_irq(&dev_priv->io_lock);
		pci_write_config_dword(dev_priv->pdev, 0x90, 0x200);

		for (i = 0; i < dev_priv->num_channels; i++) {
			chan = dev_priv->channels[i];

			if (WARN_ON_ONCE(chan->source > 3))
				continue;
			if (!((0x10 << chan->source) & pending))
				continue;
			fthd_handle_irq(dev_priv, chan);
		}
	}

	if (loops >= 500) {
		dev_err(&dev_priv->pdev->dev, "irq stuck, disabling\n");
		FTHD_ISP_REG_WRITE(0, ISP_IRQ_ENABLE);
		pci_write_config_dword(dev_priv->pdev, 0x94, 0);
		fthd_mark_firmware_wedged(dev_priv);
		return;
	}
	pci_write_config_dword(dev_priv->pdev, 0x94, 0x200);
}

static irqreturn_t fthd_irq_handler(int irq, void *arg)
{
	struct fthd_private *dev_priv = arg;
	u32 pending;
	unsigned long flags;

	spin_lock_irqsave(&dev_priv->io_lock, flags);
	pending = FTHD_ISP_REG_READ(ISP_IRQ_STATUS);
	spin_unlock_irqrestore(&dev_priv->io_lock, flags);

	if (!(pending & 0xf0))
		return IRQ_NONE;

	schedule_work(&dev_priv->irq_work);

	return IRQ_HANDLED;
}

static int fthd_irq_install(struct fthd_private *dev_priv)
{
	int ret;

	/* A single MSI vector is never shared with another device. */
	ret = request_irq(pci_irq_vector(dev_priv->pdev, 0), fthd_irq_handler, 0,
			  KBUILD_MODNAME, (void *)dev_priv);

	if (ret)
		dev_err(&dev_priv->pdev->dev, "Failed to request IRQ\n");

	return ret;
}

static int fthd_pci_set_dma_mask(struct fthd_private *dev_priv,
				 unsigned int mask)
{
	int ret;

	ret = dma_set_mask_and_coherent(&dev_priv->pdev->dev, DMA_BIT_MASK(mask));
	if (ret) {
		dev_err(&dev_priv->pdev->dev, "Failed to set %u pci dma mask\n",
			mask);
		return ret;
	}

	dev_priv->dma_mask = mask;

	return 0;
}

static void fthd_stop_firmware(struct fthd_private *dev_priv)
{
	if (!dev_priv->channel_io)
		return;

	fthd_isp_cmd_stop(dev_priv);
	isp_powerdown(dev_priv);
}

/*
 * Reboot/kexec.  Convention for .shutdown is to quiesce DMA and IRQs and go
 * no further: unlike .remove(), it must not unregister the V4L2 device or
 * free dev_priv, since a file descriptor an application still holds open has
 * to stay valid for whatever remains of this boot.  Shares fthd_suspend()'s
 * hardware transition rather than reimplementing a partial one - the same
 * "drop the stream, then power down" sequence is exactly what's needed here.
 * It does not park the stream for a resume the way fthd_suspend() does: this
 * boot has no resume left, so a reader waiting on frames has to be told.
 */
static void fthd_pci_shutdown(struct pci_dev *pdev)
{
	struct fthd_private *dev_priv = pci_get_drvdata(pdev);

	if (!dev_priv)
		return;

	mutex_lock(&dev_priv->ioctl_lock);

	if (vb2_is_busy(&dev_priv->vb2_queue))
		fthd_v4l2_suspend_stop(dev_priv, false);

	mutex_lock(&dev_priv->pm_lock);
	fthd_pm_down(dev_priv);
	mutex_unlock(&dev_priv->pm_lock);

	mutex_unlock(&dev_priv->ioctl_lock);
}

static void fthd_pci_remove(struct pci_dev *pdev)
{
	struct fthd_private *dev_priv;

	dev_priv = pci_get_drvdata(pdev);
	if (!dev_priv) {
		pci_disable_device(pdev);
		return;
	}

	/* Balance the put in probe and stop the autosuspend timer, so nothing
	 * can drop the hardware out from under the teardown below.  This does
	 * not resume the device: fthd_pm_down() is a no-op if runtime PM
	 * already parked it, and pci_disable_device() has then already run. */
	pm_runtime_get_noresume(&pdev->dev);
	pm_runtime_dont_use_autosuspend(&pdev->dev);
	pm_runtime_forbid(&pdev->dev);
	WRITE_ONCE(dev_priv->removing, true);

	fthd_debugfs_exit(dev_priv);
	fthd_v4l2_unregister(dev_priv);

	mutex_lock(&dev_priv->ioctl_lock);
	mutex_lock(&dev_priv->pm_lock);
	fthd_pm_down(dev_priv);
	mutex_unlock(&dev_priv->pm_lock);
	mutex_unlock(&dev_priv->ioctl_lock);

	pci_set_drvdata(pdev, NULL);
	fthd_put(dev_priv);
}

static int fthd_pci_init(struct fthd_private *dev_priv)
{
	struct pci_dev *pdev = dev_priv->pdev;
	int ret;


	ret = pci_enable_device(pdev);
	if (ret) {
		dev_err(&pdev->dev, "Failed to enable device\n");
		return ret;
	}

	/* ASPM must be disabled on the device or it hangs while streaming */
	pci_disable_link_state(pdev, PCIE_LINK_STATE_L0S | PCIE_LINK_STATE_L1 |
			       PCIE_LINK_STATE_CLKPM);

	ret = fthd_pci_reserve_mem(dev_priv);
	if (ret)
		goto fail_enable;

	ret = pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSI);
	if (ret < 0) {
		dev_err(&pdev->dev, "Failed to enable MSI\n");
		goto fail_reserve;
	}

	ret = fthd_irq_install(dev_priv);
	if (ret)
		goto fail_msi;

	ret = fthd_pci_set_dma_mask(dev_priv, 64);
	if (ret)
		ret = fthd_pci_set_dma_mask(dev_priv, 32);

	if (ret)
		goto fail_irq;

	dev_dbg(&pdev->dev, "Setting %ubit DMA mask\n", dev_priv->dma_mask);

	pci_set_master(pdev);
	pci_set_drvdata(pdev, dev_priv);
	return 0;

fail_irq:
	fthd_irq_uninstall(dev_priv);
fail_msi:
	pci_free_irq_vectors(pdev);
fail_reserve:
	fthd_pci_release_mem(dev_priv);
fail_enable:
	pci_disable_device(pdev);
	return ret;
}

static int fthd_firmware_start(struct fthd_private *dev_priv)
{
	int ret;

	ret = fthd_isp_cmd_start(dev_priv);
	if (ret)
		return ret;

	ret = fthd_isp_cmd_print_enable(dev_priv, 1);
	if (ret)
		return ret;

	ret = fthd_isp_cmd_camera_config(dev_priv);
	if (ret)
		return ret;

	ret = fthd_isp_cmd_channel_info(dev_priv);
	if (ret)
		return ret;

	/* Query the sensor's native resolution now so fthd_v4l2_register()
	 * can advertise it. Non-fatal: if it fails the V4L2 layer falls back
	 * to a default size. */
	ret = fthd_isp_cmd_channel_camera_config(dev_priv);
	if (ret) {
		if (READ_ONCE(dev_priv->wedged))
			return ret;
		dev_warn(&dev_priv->pdev->dev,
			 "could not query native sensor geometry: %d\n", ret);
	}

	return fthd_isp_cmd_set_loadfile(dev_priv);

}

/*
 * Take the hardware down: stop the firmware, release the interrupt, the BARs
 * and the DMA buffers, and hand the device back to the PCI core so it can drop
 * it into D3.  dev_priv, the V4L2 registration and the debugfs tree all
 * survive, so an open file descriptor and the /dev/videoN node outlive this.
 *
 * Idempotent, and the only thing that clears @suspended is fthd_pm_up().  The
 * caller holds pm_lock, except in fthd_pci_remove() where nothing else can be
 * running any more.
 */
static void fthd_pm_down(struct fthd_private *dev_priv)
{
	struct pci_dev *pdev = dev_priv->pdev;

	if (dev_priv->suspended)
		return;

	/* The channel goes with the firmware, so no image-quality command may
	 * be sent until streaming brings it back and replays the controls. */
	dev_priv->channel_running = false;

	fthd_stop_firmware(dev_priv);
	fthd_irq_uninstall(dev_priv);
	cancel_work_sync(&dev_priv->irq_work);
	fthd_hw_deinit(dev_priv);
	isp_uninit(dev_priv);
	fthd_buffer_exit(dev_priv);
	pci_clear_master(pdev);
	pci_free_irq_vectors(pdev);
	fthd_pci_release_mem(dev_priv);
	pci_disable_device(pdev);
	dev_priv->suspended = true;
	/* isp_uninit() above just reclaimed every object a timed-out command
	 * left unfreed; the next fthd_pm_up() reloads the firmware from
	 * scratch, so any earlier wedge no longer applies. */
	WRITE_ONCE(dev_priv->wedged, false);
}

/*
 * Reverse of fthd_pm_down().  The PCI core has already restored config space
 * and put the device back in D0 by the time this runs; everything above that
 * - the DDR training and the firmware image - has to be redone from scratch,
 * because powering the ISP off loses it.
 */
static int fthd_pm_up(struct fthd_private *dev_priv)
{
	struct pci_dev *pdev = dev_priv->pdev;
	int ret;

	if (!dev_priv->suspended)
		return 0;

	ret = fthd_pci_init(dev_priv);
	if (ret)
		return ret;

	ret = fthd_buffer_init(dev_priv);
	if (ret)
		goto fail_pci;

	/* Resume is on the path of every camera open(); the wide DDR check is
	 * probe-only. */
	ret = fthd_hw_init(dev_priv, false);
	if (ret)
		goto fail_buffer;

	ret = fthd_firmware_start(dev_priv);
	if (ret)
		goto fail_hw;

	dev_priv->suspended = false;
	return 0;

fail_hw:
	fthd_hw_deinit(dev_priv);
	isp_uninit(dev_priv);
fail_buffer:
	fthd_buffer_exit(dev_priv);
fail_pci:
	fthd_irq_uninstall(dev_priv);
	cancel_work_sync(&dev_priv->irq_work);
	pci_clear_master(pdev);
	pci_free_irq_vectors(pdev);
	fthd_pci_release_mem(dev_priv);
	pci_disable_device(pdev);
	return ret;
}

static int fthd_pci_probe(struct pci_dev *pdev,
			  const struct pci_device_id *entry)
{
	struct fthd_private *dev_priv;
	int ret;

	dev_info(&pdev->dev, "Found FaceTime HD camera with device id: %x\n",
		 pdev->device);

	dev_priv = kzalloc(sizeof(struct fthd_private), GFP_KERNEL);
	if (!dev_priv) {
		dev_err(&pdev->dev, "Failed to allocate memory\n");
		return -ENOMEM;
	}
	kref_init(&dev_priv->ref);
	dev_priv->pdev = pdev;

	dev_priv->ddr_model = 4;
	dev_priv->ddr_speed = 450;
	dev_priv->frame_rate = FTHD_FRAME_RATE_MAX;

	spin_lock_init(&dev_priv->io_lock);
	spin_lock_init(&dev_priv->buffer_lock);

	mutex_init(&dev_priv->ioctl_lock);
	mutex_init(&dev_priv->pm_lock);
	mutex_init(&dev_priv->mem_lock);
	INIT_LIST_HEAD(&dev_priv->mem_objects);
	INIT_WORK(&dev_priv->irq_work, fthd_irq_work);

	ret = fthd_pci_init(dev_priv);
	if (ret)
		goto fail_work;

	ret = fthd_buffer_init(dev_priv);
	if (ret)
		goto fail_pci;

	/* Probe happens once, so it pays for the wider DDR check. */
	ret = fthd_hw_init(dev_priv, true);
	if (ret)
		goto fail_buffer;

	ret = fthd_firmware_start(dev_priv);
	if (ret)
		goto fail_hw;

	ret = fthd_v4l2_register(dev_priv);
	if (ret)
		goto fail_firmware;

	ret = fthd_debugfs_init(dev_priv);
	if (ret)
		goto fail_v4l2;

	/* One line per probe, carrying what the twenty-line bring-up banner
	 * used to be read for. Everything else on that path is dev_dbg now,
	 * because runtime PM replays it on every resume. */
	dev_info(&pdev->dev, "camera ready: DDR %u MHz, %u-bit DMA\n",
		 dev_priv->ddr_speed, dev_priv->dma_mask);

	pm_runtime_set_autosuspend_delay(&pdev->dev, FTHD_AUTOSUSPEND_DELAY_MS);
	pm_runtime_use_autosuspend(&pdev->dev);
	/* The PCI core forbids runtime PM on a device until either userspace
	 * (power/control) or the driver explicitly opts in. */
	if (runtime_pm)
		pm_runtime_allow(&pdev->dev);
	/* pci_device_probe() took a runtime-PM reference and leaves it to the
	 * driver to drop.  From here on the camera is only powered while
	 * something has it open. */
	fthd_pm_put(dev_priv);
	return 0;
fail_v4l2:
	fthd_v4l2_unregister(dev_priv);
fail_firmware:
	fthd_stop_firmware(dev_priv);
fail_hw:
	fthd_hw_deinit(dev_priv);
	isp_uninit(dev_priv);
fail_buffer:
	fthd_buffer_exit(dev_priv);
fail_pci:
	fthd_irq_uninstall(dev_priv);
	cancel_work_sync(&dev_priv->irq_work);
	pci_clear_master(pdev);
	pci_free_irq_vectors(pdev);
	fthd_pci_release_mem(dev_priv);
	pci_disable_device(pdev);
	pci_set_drvdata(pdev, NULL);

fail_work:
	cancel_work_sync(&dev_priv->irq_work);
	fthd_put(dev_priv);
	return ret;
}

#ifdef CONFIG_PM
/*
 * Runtime PM.  These run with no V4L2 lock held - a runtime resume is reached
 * from open() and from the debugfs accessors - so they take pm_lock only.
 */
static int fthd_runtime_suspend(struct device *dev)
{
	struct fthd_private *dev_priv = dev_get_drvdata(dev);
	int ret = 0;

	if (!dev_priv)
		return 0;

	mutex_lock(&dev_priv->pm_lock);
	/* Streaming holds a runtime-PM reference through the open file
	 * descriptor, so this should be unreachable during ordinary runtime PM;
	 * refuse rather than pull the buffers out from under vb2 if it ever is
	 * not.  System sleep is different: fthd_suspend() has already stopped
	 * the channel, returned every buffer with an error and released its ISP
	 * mappings, but the vb2 allocations intentionally survive for userspace
	 * to recover with STREAMOFF/STREAMON after resume. */
	if (vb2_is_busy(&dev_priv->vb2_queue) &&
	    !dev_priv->system_suspending) {
		ret = -EBUSY;
		goto out_unlock;
	}

	fthd_pm_down(dev_priv);

out_unlock:
	mutex_unlock(&dev_priv->pm_lock);
	return ret;
}

static int fthd_runtime_resume(struct device *dev)
{
	struct fthd_private *dev_priv = dev_get_drvdata(dev);
	int ret;

	if (!dev_priv)
		return 0;

	mutex_lock(&dev_priv->pm_lock);
	ret = fthd_pm_up(dev_priv);
	mutex_unlock(&dev_priv->pm_lock);
	return ret;
}

/* Whether the ISP is up right now.  The sleep callbacks need it to tell "put
 * the stream back" apart from "the camera is parked and nothing may talk to
 * it"; @suspended is pm_lock's to answer. */
static bool fthd_is_powered(struct fthd_private *dev_priv)
{
	bool powered;

	mutex_lock(&dev_priv->pm_lock);
	powered = !dev_priv->suspended;
	mutex_unlock(&dev_priv->pm_lock);

	return powered;
}

/*
 * System sleep.  Same hardware transition as the runtime path, but a system
 * suspend can arrive with the device open, so it takes the V4L2 ioctl lock to
 * shut userspace out for the duration.  pm_runtime_force_suspend()/resume()
 * invoke the runtime callbacks above, preserving the lock order ioctl_lock ->
 * pm_lock.
 *
 * It must not reuse fthd_runtime_suspend()'s refusal: a runtime suspend that
 * returns -EBUSY is just deferred, while an error here aborts the entire sleep
 * transition and leaves the machine awake.  A camera left streaming - by an
 * app the user forgot about, or one that had not noticed the lid closing - is
 * an ordinary thing to suspend with, so the stream is parked instead, and
 * fthd_resume() puts it back.
 */
static int __maybe_unused fthd_suspend(struct device *dev)
{
	struct fthd_private *dev_priv = dev_get_drvdata(dev);
	int ret;

	if (!dev_priv)
		return 0;

	mutex_lock(&dev_priv->ioctl_lock);

	if (vb2_is_busy(&dev_priv->vb2_queue))
		fthd_v4l2_suspend_stop(dev_priv, true);

	/* The force helpers use the runtime-PM usage count to remember whether
	 * the camera was actually in use.  In particular, an idle camera still
	 * waiting out its autosuspend delay is left off after resume instead of
	 * needlessly reloading its firmware and immediately tearing it down. */
	dev_priv->system_suspending = true;
	ret = pm_runtime_force_suspend(dev);
	if (ret) {
		dev_priv->system_suspending = false;
		/* The PM core does not resume a device whose suspend failed, so
		 * fthd_resume() will not run and nothing else would ever unpark
		 * the stream stopped above. */
		fthd_v4l2_resume_start(dev_priv, fthd_is_powered(dev_priv));
	}

	mutex_unlock(&dev_priv->ioctl_lock);
	return ret;
}

static int __maybe_unused fthd_resume(struct device *dev)
{
	struct fthd_private *dev_priv = dev_get_drvdata(dev);
	int ret;

	if (!dev_priv)
		return 0;

	mutex_lock(&dev_priv->ioctl_lock);
	/* This reloads the ISP only when a runtime-PM reference was held before
	 * system sleep.  Otherwise the camera remains runtime-suspended until
	 * the next open(). */
	ret = pm_runtime_force_resume(dev);
	dev_priv->system_suspending = false;

	/* Restart the stream fthd_suspend() parked, before userspace is thawed.
	 * Only a stream can have parked anything, and one cannot exist without
	 * an open fd holding a runtime-PM reference, so the force-resume above
	 * has necessarily powered the hardware back up by the time this matters.
	 * It reloads no firmware of its own; the cost is the channel-start
	 * command sequence, paid only when something was actually capturing. */
	fthd_v4l2_resume_start(dev_priv, fthd_is_powered(dev_priv));

	mutex_unlock(&dev_priv->ioctl_lock);
	return ret;
}

static const struct dev_pm_ops fthd_pm_ops = {
	SET_SYSTEM_SLEEP_PM_OPS(fthd_suspend, fthd_resume)
	SET_RUNTIME_PM_OPS(fthd_runtime_suspend, fthd_runtime_resume, NULL)
};
#endif /* CONFIG_PM */

/*
 * AER/DPC: the PCI core has already decided the link is unusable.  There is
 * no channel_io left to send a graceful CISP_CMD_STOP down, and no BAR left
 * worth touching, so this does not attempt fthd_pm_down()'s normal hardware
 * transition - only wakes up whatever is blocked waiting on the device.
 * Without this, a reader blocked in DQBUF or v4l2-compliance's poll() would
 * hang until the process is killed instead of getting -EIO back.
 */
static pci_ers_result_t fthd_pci_error_detected(struct pci_dev *pdev,
						pci_channel_state_t state)
{
	struct fthd_private *dev_priv = pci_get_drvdata(pdev);

	if (!dev_priv)
		return PCI_ERS_RESULT_DISCONNECT;

	dev_err(&pdev->dev, "PCI error detected (state %d), disconnecting\n", state);

	mutex_lock(&dev_priv->ioctl_lock);
	fthd_mark_firmware_wedged(dev_priv);
	mutex_unlock(&dev_priv->ioctl_lock);

	return PCI_ERS_RESULT_DISCONNECT;
}

static const struct pci_error_handlers fthd_pci_err_handler = {
	.error_detected = fthd_pci_error_detected,
};

static const struct pci_device_id fthd_pci_id_table[] = {
	{ PCI_DEVICE(0x14e4, 0x1570) },
	{ 0, },
};

static struct pci_driver fthd_pci_driver = {
	.name = KBUILD_MODNAME,
	.probe = fthd_pci_probe,
	.remove = fthd_pci_remove,
	.shutdown = fthd_pci_shutdown,
	.id_table = fthd_pci_id_table,
	.err_handler = &fthd_pci_err_handler,
#ifdef CONFIG_PM
	.driver.pm = &fthd_pm_ops,
#endif
};

module_pci_driver(fthd_pci_driver);

MODULE_FIRMWARE("facetimehd/firmware.bin");
MODULE_FIRMWARE("facetimehd/1222_01XX.dat");
MODULE_FIRMWARE("facetimehd/1571_01XX.dat");
MODULE_FIRMWARE("facetimehd/1575_01XX.dat");
MODULE_FIRMWARE("facetimehd/1671_01XX.dat");
MODULE_FIRMWARE("facetimehd/1674_01XX.dat");
MODULE_FIRMWARE("facetimehd/1675_01XX.dat");
MODULE_FIRMWARE("facetimehd/1771_01XX.dat");
MODULE_FIRMWARE("facetimehd/1871_01XX.dat");
MODULE_FIRMWARE("facetimehd/1874_01XX.dat");
MODULE_FIRMWARE("facetimehd/8221_01XX.dat");
MODULE_FIRMWARE("facetimehd/9112_01XX.dat");
MODULE_DEVICE_TABLE(pci, fthd_pci_id_table);
MODULE_AUTHOR("Patrik Jakobsson <patrik.r.jakobsson@gmail.com>");
MODULE_DESCRIPTION("FacetimeHD camera driver");
MODULE_LICENSE("GPL");
