#include "CLlamaBridge.h"

#include <llama.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct lllm_runtime {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    const llama_vocab * vocab = nullptr;
    int32_t context_size = 0;
    std::string chat_template;
    std::mutex mutex;
};

namespace {

std::once_flag backend_once;

void silent_log_callback(enum ggml_log_level, const char *, void *) {}

void ensure_backend() {
    std::call_once(backend_once, [] {
        llama_log_set(silent_log_callback, nullptr);
        llama_backend_init();
    });
}

void set_error(char * error_buffer, int32_t error_buffer_length, const std::string & message) {
    if (error_buffer == nullptr || error_buffer_length <= 0) {
        return;
    }

    const auto copy_length = std::min<int32_t>(
        static_cast<int32_t>(message.size()),
        error_buffer_length - 1
    );
    std::memcpy(error_buffer, message.data(), copy_length);
    error_buffer[copy_length] = '\0';
}

std::string gemma_prompt(const char * prompt) {
    std::string user_prompt = prompt == nullptr ? "" : prompt;
    return "<|turn>user\n" + user_prompt + "<turn|>\n<|turn>model\n";
}

bool tokenize(
    const llama_vocab * vocab,
    const std::string & text,
    std::vector<llama_token> & tokens,
    std::string & error
) {
    int32_t capacity = static_cast<int32_t>(text.size()) + 32;
    tokens.resize(std::max<int32_t>(capacity, 128));

    int32_t count = llama_tokenize(
        vocab,
        text.c_str(),
        static_cast<int32_t>(text.size()),
        tokens.data(),
        static_cast<int32_t>(tokens.size()),
        true,
        true
    );

    if (count < 0) {
        tokens.resize(-count);
        count = llama_tokenize(
            vocab,
            text.c_str(),
            static_cast<int32_t>(text.size()),
            tokens.data(),
            static_cast<int32_t>(tokens.size()),
            true,
            true
        );
    }

    if (count < 0) {
        error = "Failed to tokenize prompt.";
        return false;
    }

    tokens.resize(count);
    return true;
}

std::string token_to_string(const llama_vocab * vocab, llama_token token) {
    char stack_buffer[256];
    int32_t written = llama_token_to_piece(
        vocab,
        token,
        stack_buffer,
        static_cast<int32_t>(sizeof(stack_buffer)),
        0,
        false
    );

    if (written >= 0) {
        return std::string(stack_buffer, stack_buffer + written);
    }

    std::vector<char> buffer(-written);
    written = llama_token_to_piece(
        vocab,
        token,
        buffer.data(),
        static_cast<int32_t>(buffer.size()),
        0,
        false
    );

    if (written < 0) {
        return "";
    }

    return std::string(buffer.data(), buffer.data() + written);
}

llama_batch single_token_batch(llama_token * token) {
    return llama_batch_get_one(token, 1);
}

} // namespace

lllm_runtime * lllm_runtime_create(
    const char * model_path,
    int32_t context_size,
    int32_t gpu_layers,
    int32_t threads,
    char * error_buffer,
    int32_t error_buffer_length
) {
    ensure_backend();

    if (model_path == nullptr || std::strlen(model_path) == 0) {
        set_error(error_buffer, error_buffer_length, "Model path is empty.");
        return nullptr;
    }

    auto * runtime = new lllm_runtime();

    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = gpu_layers;
    model_params.use_mmap = true;

    runtime->model = llama_model_load_from_file(model_path, model_params);
    if (runtime->model == nullptr) {
        delete runtime;
        set_error(error_buffer, error_buffer_length, "Failed to load llama.cpp model.");
        return nullptr;
    }

    llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = context_size > 0 ? static_cast<uint32_t>(context_size) : 4096;
    context_params.n_batch = std::min<uint32_t>(context_params.n_ctx, 2048);
    context_params.n_threads = threads > 0 ? threads : static_cast<int32_t>(std::thread::hardware_concurrency());
    context_params.n_threads_batch = context_params.n_threads;
    context_params.no_perf = true;

    runtime->context = llama_init_from_model(runtime->model, context_params);
    if (runtime->context == nullptr) {
        llama_model_free(runtime->model);
        delete runtime;
        set_error(error_buffer, error_buffer_length, "Failed to create llama.cpp context.");
        return nullptr;
    }

    runtime->vocab = llama_model_get_vocab(runtime->model);
    if (runtime->vocab == nullptr) {
        llama_free(runtime->context);
        llama_model_free(runtime->model);
        delete runtime;
        set_error(error_buffer, error_buffer_length, "Failed to load llama.cpp vocabulary.");
        return nullptr;
    }

    runtime->context_size = static_cast<int32_t>(context_params.n_ctx);

    const int32_t needed = llama_model_meta_val_str(runtime->model, "tokenizer.chat_template", nullptr, 0);
    if (needed > 0) {
        runtime->chat_template.resize(static_cast<size_t>(needed));
        const int32_t written = llama_model_meta_val_str(
            runtime->model,
            "tokenizer.chat_template",
            runtime->chat_template.data(),
            static_cast<size_t>(runtime->chat_template.size())
        );
        if (written > 0 && written < needed) {
            runtime->chat_template.resize(static_cast<size_t>(written));
        }
    }

    return runtime;
}

void lllm_runtime_destroy(lllm_runtime * runtime) {
    if (runtime == nullptr) {
        return;
    }

    if (runtime->context != nullptr) {
        llama_free(runtime->context);
    }
    if (runtime->model != nullptr) {
        llama_model_free(runtime->model);
    }
    delete runtime;
}

int32_t lllm_runtime_context_size(lllm_runtime * runtime) {
    if (runtime == nullptr || runtime->context == nullptr) {
        return 0;
    }

    return runtime->context_size;
}

const char * lllm_runtime_chat_template(lllm_runtime * runtime) {
    if (runtime == nullptr || runtime->chat_template.empty()) {
        return nullptr;
    }

    return runtime->chat_template.c_str();
}

int32_t lllm_runtime_count_prompt_tokens(
    lllm_runtime * runtime,
    const char * prompt,
    char * error_buffer,
    int32_t error_buffer_length
) {
    if (runtime == nullptr || runtime->vocab == nullptr) {
        set_error(error_buffer, error_buffer_length, "Runtime is not loaded.");
        return -1;
    }

    std::lock_guard<std::mutex> guard(runtime->mutex);

    std::vector<llama_token> tokens;
    std::string error;
    const auto formatted_prompt = gemma_prompt(prompt);
    if (!tokenize(runtime->vocab, formatted_prompt, tokens, error)) {
        set_error(error_buffer, error_buffer_length, error);
        return -2;
    }

    return static_cast<int32_t>(tokens.size());
}

int32_t lllm_runtime_generate(
    lllm_runtime * runtime,
    const char * prompt,
    int32_t max_tokens,
    float temperature,
    lllm_token_callback callback,
    void * user_data,
    char * error_buffer,
    int32_t error_buffer_length
) {
    if (runtime == nullptr || runtime->context == nullptr || runtime->vocab == nullptr) {
        set_error(error_buffer, error_buffer_length, "Runtime is not loaded.");
        return -1;
    }

    std::lock_guard<std::mutex> guard(runtime->mutex);

    llama_memory_clear(llama_get_memory(runtime->context), true);

    std::vector<llama_token> tokens;
    std::string error;
    const auto formatted_prompt = gemma_prompt(prompt);
    if (!tokenize(runtime->vocab, formatted_prompt, tokens, error)) {
        set_error(error_buffer, error_buffer_length, error);
        return -2;
    }

    llama_batch batch = llama_batch_get_one(tokens.data(), static_cast<int32_t>(tokens.size()));
    int32_t decode_status = llama_decode(runtime->context, batch);
    if (decode_status != 0) {
        set_error(error_buffer, error_buffer_length, "Failed to decode prompt.");
        return -3;
    }

    llama_sampler_chain_params sampler_params = llama_sampler_chain_default_params();
    sampler_params.no_perf = true;
    llama_sampler * sampler = llama_sampler_chain_init(sampler_params);
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(64));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95f, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05f, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature > 0 ? temperature : 0.7f));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    const int32_t limit = max_tokens > 0 ? max_tokens : 512;
    int32_t produced = 0;

    for (; produced < limit; produced += 1) {
        llama_token next_token = llama_sampler_sample(sampler, runtime->context, -1);
        if (llama_vocab_is_eog(runtime->vocab, next_token)) {
            break;
        }

        const std::string piece = token_to_string(runtime->vocab, next_token);
        if (callback != nullptr && !piece.empty()) {
            callback(piece.c_str(), user_data);
        }

        llama_batch next_batch = single_token_batch(&next_token);
        decode_status = llama_decode(runtime->context, next_batch);
        if (decode_status != 0) {
            llama_sampler_free(sampler);
            set_error(error_buffer, error_buffer_length, "Failed while generating response.");
            return -4;
        }
    }

    llama_sampler_free(sampler);
    return produced;
}
