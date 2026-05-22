#pragma once

#include <stdint.h>
#include <stddef.h>

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

__attribute__((deprecated("Use lllm_count_tokens which does not wrap the input in a turn template.")))
int32_t lllm_runtime_count_prompt_tokens(
    lllm_runtime * runtime,
    const char * prompt,
    char * error_buffer,
    int32_t error_buffer_length
);

__attribute__((deprecated("Use lllm_runtime_generate_v2 with lllm_sampler_params and lllm_token_callback_v2 for the full sampler / grammar / stop / cancellation surface.")))
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

typedef struct {
    int32_t  max_tokens;
    float    temperature;
    float    top_p;
    int32_t  top_k;
    float    min_p;
    float    repeat_penalty;
    uint32_t seed;
} lllm_sampler_params;

// Callback returns 0 to continue, non-zero to stop cooperatively.
typedef int (*lllm_token_callback_v2)(const char * token_utf8, void * user_data);

int32_t lllm_runtime_generate_v2(
    lllm_runtime *            rt,
    const char *              prompt,
    lllm_sampler_params       params,
    const char *              grammar_gbnf,
    const char * const *      stop_sequences,
    lllm_token_callback_v2    callback,
    void *                    user_data,
    char *                    error_buf, int32_t error_buf_length);

// === Audio input ===

// Audio attachment passed from Swift. Contract:
//   - `samples` is a contiguous mono Float32 buffer; `n_samples` is the total
//     per-channel sample count (= total since mono).
//   - All values MUST be finite (no NaN, no +/-Inf) and in [-1.0, 1.0]; values
//     outside the range are hard-clamped Swift-side BEFORE this struct is
//     populated. Non-finite values cause the Swift call to throw
//     LocalLLMError.audioContainsNonFinite pre-flight; they are never passed
//     across the FFI. The bridge does no validation of these; caller's
//     responsibility.
//   - Sample rate equals lllm_runtime_audio_sample_rate(rt) (16000 for Gemma 4);
//     this is enforced Swift-side as audioSampleRateMismatch if violated.
//   - `samples` is not owned; the buffer must remain valid for the duration of
//     the lllm_runtime_generate_v2_media call.
typedef struct {
    const float * samples;
    size_t        n_samples;
} lllm_audio_input;

// Idempotent. Initializes the mtmd context against the already-loaded model.
// Returns 0 on success, negative on error:
//   -1 : mtmd_init_from_file returned null
//   -2 : model does not support audio input
//   -3 : mmproj_path missing or empty
int32_t lllm_runtime_load_mmproj(
    lllm_runtime * rt,
    const char *   mmproj_path,
    char *         error_buf, int32_t error_buf_length);

// 0 if mmproj not loaded or model does not support audio; else the sample rate
// (16000 for Gemma 4). Upstream mtmd_get_audio_sample_rate returns -1 on
// unsupported; this wrapper normalizes that to 0.
int32_t lllm_runtime_audio_sample_rate(lllm_runtime * rt);

// Returns the marker (e.g. "<__media__>") that must appear in the prompt where
// each audio chunk should sit. NULL if mmproj not loaded. Pointer owned by
// runtime; do not free.
const char * lllm_runtime_media_marker(lllm_runtime * rt);

// Same sampler/grammar/stops/cancel contract as lllm_runtime_generate_v2.
// `prompt` MUST contain exactly `n_audio` occurrences of the media marker.
//
// Negative return codes (scoped to THIS function):
//   -3 : prefill failed
//   -4 : decode-loop failure (same meaning as in generate_v2)
//   -5 : mtmd_tokenize returned 1 (marker count != bitmap count)
//   -6 : mtmd_helper_eval_chunk_single non-zero
//   -7 : grammar parse failed
//   -8 : mmproj not loaded
//   -9 : mtmd_tokenize returned 2 (audio preprocessing error)
int32_t lllm_runtime_generate_v2_media(
    lllm_runtime *               rt,
    const char *                 prompt,
    lllm_sampler_params          params,
    const char *                 grammar_gbnf,
    const char * const *         stop_sequences,
    const lllm_audio_input *     audios,
    size_t                       n_audio,
    lllm_token_callback_v2       callback,
    void *                       user_data,
    int32_t *                    out_prompt_tokens,
    char *                       error_buf, int32_t error_buf_length);

// Frees memory returned by malloc'd C-string entry points.
void lllm_string_free(char * s);

#ifdef __cplusplus
}
#endif
