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

// Render a chat using the model's embedded Jinja template. Returns malloc'd
// UTF-8 string; caller frees with lllm_string_free. NULL on error, error_buf
// populated. See spec §7.3 for the error-string contract.
char * lllm_chat_render(
    lllm_runtime * rt,
    const char *   messages_json,
    const char *   tools_json,
    int            enable_thinking,
    char *         error_buf, int32_t error_buf_length);

// Parse a complete assistant-turn string into OpenAI-compatible JSON of shape
// {"content": "...", "reasoning": "..." or null, "tool_calls": [...]}.
// Format is detected from the model's chat template via common_chat_parse.
// Returns malloc'd UTF-8; NULL on error, error_buf populated.
char * lllm_parse_assistant_turn(
    lllm_runtime * rt,
    const char *   assistant_output,
    char *         error_buf, int32_t error_buf_length);

int32_t lllm_count_tokens(lllm_runtime* rt, const char* text, char* error_buf, int32_t error_buf_length);

// Frees memory returned by malloc'd C-string entry points.
void lllm_string_free(char * s);

#ifdef __cplusplus
}
#endif
