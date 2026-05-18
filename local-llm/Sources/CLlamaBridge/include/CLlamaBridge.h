#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lllm_runtime lllm_runtime;

typedef void (*lllm_token_callback)(const char * token, void * user_data);

lllm_runtime * lllm_runtime_create(
    const char * model_path,
    int32_t context_size,
    int32_t gpu_layers,
    int32_t threads,
    char * error_buffer,
    int32_t error_buffer_length
);

void lllm_runtime_destroy(lllm_runtime * runtime);

int32_t lllm_runtime_context_size(lllm_runtime * runtime);

int32_t lllm_runtime_count_prompt_tokens(
    lllm_runtime * runtime,
    const char * prompt,
    char * error_buffer,
    int32_t error_buffer_length
);

int32_t lllm_runtime_generate(
    lllm_runtime * runtime,
    const char * prompt,
    int32_t max_tokens,
    float temperature,
    lllm_token_callback callback,
    void * user_data,
    char * error_buffer,
    int32_t error_buffer_length
);

#ifdef __cplusplus
}
#endif
