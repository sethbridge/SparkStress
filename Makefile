NVCC ?= nvcc
ARCH ?= sm_121
CFLAGS ?= -O3

gpu_stress: gpu_stress.cu
	$(NVCC) $(CFLAGS) -arch=$(ARCH) -o $@ $< -lcublas

clean:
	rm -f gpu_stress

.PHONY: clean
