/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * FacetimeHD camera driver
 *
 * Copyright (C) 2015 Sven Schnelle <svens@stackframe.org>
 *
 */

#include <linux/dma-mapping.h>
#include <linux/printk.h>
#include "fthd_drv.h"
#include "fthd_isp.h"
#include "fthd_hw.h"
#include "fthd_buffer.h"

static int iommu_allocator_init(struct fthd_private *dev_priv)
{
	dev_priv->iommu = kzalloc(sizeof(struct resource), GFP_KERNEL);
	if (!dev_priv->iommu)
		return -ENOMEM;

	dev_priv->iommu->start = 0;
	dev_priv->iommu->end = 4095;
	return 0;
}

struct iommu_obj *iommu_allocate_sgtable(struct fthd_private *dev_priv, struct sg_table *sgtable)
{
	struct iommu_obj *obj;
	struct resource *root = dev_priv->iommu;
	struct scatterlist *sg;
	resource_size_t total_pages = 0;
	unsigned int byte_offset = 0;
	unsigned int pages, page;
	size_t dma_length;
	int ret, i;
	u32 pos;
	dma_addr_t dma_addr;
	u64 dma_page;

	if (!sgtable || !sgtable->sgl || !sgtable->nents)
		return NULL;

	/* DMA scatterlists may be chained, so they must never be walked with
	 * pointer arithmetic.  The S2 page table also cannot represent a gap in
	 * the middle of a logical buffer: only the first segment may start at a
	 * non-page-aligned address and only the final segment may end there. */
	for_each_sg(sgtable->sgl, sg, sgtable->nents, i) {
		dma_addr = sg_dma_address(sg);
		dma_length = sg_dma_len(sg);
		if (!dma_length)
			return NULL;

		if (!i)
			byte_offset = offset_in_page(dma_addr);

		if ((i > 0 && offset_in_page(dma_addr)) ||
		    (i + 1 < sgtable->nents &&
		     offset_in_page(dma_addr + dma_length))) {
			dev_err(&dev_priv->pdev->dev,
				"Buffer segment %d is not page aligned (%pad, len %zu), refusing\n",
				i, &dma_addr, dma_length);
			return NULL;
		}

		pages = DIV_ROUND_UP(offset_in_page(dma_addr) + dma_length,
				     PAGE_SIZE);
		dma_page = dma_addr >> PAGE_SHIFT;
		if (dma_page > U32_MAX || pages - 1 > U32_MAX - dma_page)
			return NULL;
		if (pages > resource_size(root) - total_pages)
			return NULL;
		total_pages += pages;
	}

	if (!total_pages)
		return NULL;

	obj = kzalloc(sizeof(struct iommu_obj), GFP_KERNEL);
	if (!obj)
		return NULL;

	obj->base.name = "S2 IOMMU";
	ret = allocate_resource(root, &obj->base, total_pages, root->start, root->end,
				1, NULL, NULL);
	if (ret) {
		dev_err(&dev_priv->pdev->dev,
			"Failed to allocate resource (size: %pa, start: %pa, end: %pa)\n",
			&total_pages, &root->start, &root->end);
		kfree(obj);
		return NULL;
	}

	obj->offset = obj->base.start - root->start;
	obj->size = total_pages;
	obj->byte_offset = byte_offset;

	pos = 0x9000 + obj->offset * 4;
	for_each_sg(sgtable->sgl, sg, sgtable->nents, i) {
		dma_addr = sg_dma_address(sg);
		dma_length = sg_dma_len(sg);
		pages = DIV_ROUND_UP(offset_in_page(dma_addr) + dma_length,
				     PAGE_SIZE);
		dma_page = dma_addr >> PAGE_SHIFT;

		for (page = 0; page < pages; page++) {
			FTHD_S2_REG_WRITE((u32)dma_page++, pos);
			pos += 4;
		}
	}

	pr_debug("allocated %d pages @ %p / offset %d\n", obj->size, obj, obj->offset);
	return obj;
}

void iommu_free(struct fthd_private *dev_priv, struct iommu_obj *obj)
{
	int i;
	pr_debug("freeing %p\n", obj);

	if (!obj)
		return;
	
 	for (i = obj->offset; i < obj->offset + obj->size; i++)
		FTHD_S2_REG_WRITE(0, 0x9000 + i * 4);

	release_resource(&obj->base);
	kfree(obj);
	obj = NULL;
}

static void iommu_allocator_destroy(struct fthd_private *dev_priv)
{
	kfree(dev_priv->iommu);
	dev_priv->iommu = NULL;
}

int fthd_buffer_init(struct fthd_private *dev_priv)
{
	int i;
	for(i = 0; i < 0x1000; i++)
		FTHD_S2_REG_WRITE(0, 0x9000 + i * 4);

	return iommu_allocator_init(dev_priv);
}

void fthd_buffer_exit(struct fthd_private *dev_priv)
{
	iommu_allocator_destroy(dev_priv);
}
