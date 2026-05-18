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

// Returns a pointer to the model tokenizer.chat_template metadata value, or NULL if the GGUF does not carry one.
// The pointer is owned by the runtime and valid until lllm_runtime_destroy.
const char * lllm_runtime_chat_template(lllm_runtime * runtime);

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

// SPIKE-ONLY: render a chat using the model's embedded template.
// messages_json: JSON array of {role, content, ...} (OpenAI-compat).
// tools_json:    JSON array of OpenAI-compat tool defs, or NULL/"".
// Returns malloc'd UTF-8; caller frees with lllm_string_free. NULL on error,
// error_buf populated. This entry point will be replaced by lllm_chat_render
// in Task 1.1.
char * lllm_spike_render(
    lllm_runtime * rt,
    const char *   messages_json,
    const char *   tools_json,
    char *         error_buf, int32_t error_buf_length);

// Frees memory returned by malloc'd C-string entry points (e.g. lllm_spike_render).
void lllm_string_free(char * s);

#ifdef __cplusplus
}
#endif
