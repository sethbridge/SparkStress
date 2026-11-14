// gpu_stress.cu — sustained cuBLAS SGEMM load for thermal testing on GB10 (sm_121).
// Writes a heartbeat + throughput line to a status file every 10 GEMMs so a
// watchdog can confirm the GPU is still under load.
//
// Usage: gpu_stress [status_file]     (default: /tmp/sparkstress/gpu_status.txt)
// Stop with SIGTERM/SIGKILL — there is no idle mode.
#include <cublas_v2.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <sys/stat.h>
#include <sys/types.h>

#define CHECK(x) do { auto _e = (x); \
    if (_e != cudaSuccess) { \
      fprintf(stderr, "CUDA error %d at line %d\n", (int)_e, __LINE__); exit(2); } } while (0)

#define CHECK_CUBLAS(x) do { auto _e = (x); \
    if (_e != CUBLAS_STATUS_SUCCESS) { \
      fprintf(stderr, "cuBLAS error %d at line %d\n", (int)_e, __LINE__); exit(2); } } while (0)

int main(int argc, char** argv) {
    const char* status_path = (argc > 1) ? argv[1] : "/tmp/sparkstress/gpu_status.txt";

    cublasHandle_t h;
    CHECK_CUBLAS(cublasCreate(&h));

    const int N = 8192;
    size_t bytes = (size_t)N * N * sizeof(float);
    float *a, *b, *c;
    CHECK(cudaMalloc(&a, bytes));
    CHECK(cudaMalloc(&b, bytes));
    CHECK(cudaMalloc(&c, bytes));
    // 0x3f3f3f3f ~= 1.015f per float — values only matter for load, not numerics
    CHECK(cudaMemset(a, 0x3f, bytes));
    CHECK(cudaMemset(b, 0x3f, bytes));

    const float alpha = 1.0f, beta = 0.0f;
    auto t0 = std::chrono::steady_clock::now();
    double start = std::chrono::duration<double>(t0.time_since_epoch()).count();
    long iters = 0;

    // create the status file's parent directory if it does not exist
    {
        char tmp[4096];
        snprintf(tmp, sizeof(tmp), "%s", status_path);
        char* slash = strrchr(tmp, '/');
        if (slash && slash != tmp) { *slash = '\0'; mkdir(tmp, 0755); }
    }
    FILE* status = fopen(status_path, "w");
    if (!status) { fprintf(stderr, "cannot open %s\n", status_path); exit(3); }
    fprintf(status, "started path=%s\n", status_path);
    fflush(status);

    for (;;) {
        CHECK_CUBLAS(cublasSgemm(h, CUBLAS_OP_N, CUBLAS_OP_N, N, N, N, &alpha, a, N, b, N, &beta, c, N));
        // Pace host to GPU: avoids unbounded enqueue backlog, so killing the
        // process stops the load promptly and the heartbeat is meaningful.
        CHECK(cudaDeviceSynchronize());
        if (++iters % 10 == 0) {
            auto now = std::chrono::steady_clock::now();
            double t1 = std::chrono::duration<double>(now.time_since_epoch()).count();
            double dt = t1 - start;
            double gflops = 2.0 * (double)N * N * N * iters / dt / 1e9;
            fprintf(status, "iter=%ld gflops=%.1f uptime=%.1f ts=%.0f\n", iters, gflops, dt, t1);
            fflush(status);
        }
    }

    cudaFree(a); cudaFree(b); cudaFree(c);
    cublasDestroy(h);
    return 0;
}
