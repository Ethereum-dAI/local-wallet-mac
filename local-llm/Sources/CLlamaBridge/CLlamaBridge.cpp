#include "CLlamaBridge.h"

#include <llama.h>
#include "chat.h"
#include "nlohmann/json.hpp"

#include <algorithm>
#include <atomic>
#include <cstdlib>
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

common_reasoning_format default_reasoning_format() {
    return COMMON_REASONING_FORMAT_AUTO;
}

char * serialize_parsed_to_c_string(
    const common_chat_msg & parsed,
    char * error_buf,
    int32_t error_buf_length
) {
    try {
        nlohmann::ordered_json parsed_json = parsed.to_json_oaicompat();
        nlohmann::ordered_json output = nlohmann::ordered_json::object();

        output["content"] = parsed_json.contains("content")
            ? parsed_json["content"]
            : nlohmann::ordered_json("");
        output["reasoning"] = parsed_json.contains("reasoning_content") && !parsed_json["reasoning_content"].is_null()
            ? parsed_json["reasoning_content"]
            : nlohmann::ordered_json(nullptr);
        output["tool_calls"] = parsed_json.contains("tool_calls") && parsed_json["tool_calls"].is_array()
            ? parsed_json["tool_calls"]
            : nlohmann::ordered_json::array();

        const std::string serialized = output.dump();
        char * result = static_cast<char *>(std::malloc(serialized.size() + 1));
        if (result == nullptr) {
            set_error(error_buf, error_buf_length, "out of memory");
            return nullptr;
        }

        std::memcpy(result, serialized.data(), serialized.size());
        result[serialized.size()] = '\0';
        return result;
    } catch (const std::exception & e) {
        set_error(error_buf, error_buf_length, std::string("Assistant turn serialization failed: ") + e.what());
        return nullptr;
    }
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

char * lllm_chat_render(
    lllm_runtime * rt,
    const char *   messages_json,
    const char *   tools_json,
    int            enable_thinking,
    char *         error_buf,
    int32_t        error_buf_length
) {
    if (rt == nullptr || rt->model == nullptr) {
        set_error(error_buf, error_buf_length, "Runtime is not loaded.");
        return nullptr;
    }
    if (rt->chat_template.empty()) {
        set_error(error_buf, error_buf_length, "Model is missing chat template metadata");
        return nullptr;
    }
    if (messages_json == nullptr) {
        set_error(error_buf, error_buf_length, "messages_json: NULL");
        return nullptr;
    }

    nlohmann::ordered_json msgs_json;
    try {
        msgs_json = nlohmann::ordered_json::parse(messages_json);
    } catch (const std::exception & e) {
        set_error(error_buf, error_buf_length, std::string("messages_json: ") + e.what());
        return nullptr;
    }
    nlohmann::ordered_json tools_json_value = nlohmann::ordered_json::array();
    if (tools_json != nullptr && tools_json[0] != '\0') {
        try {
            tools_json_value = nlohmann::ordered_json::parse(tools_json);
        } catch (const std::exception & e) {
            set_error(error_buf, error_buf_length, std::string("tools_json: ") + e.what());
            return nullptr;
        }
    }

    try {
        common_chat_templates_ptr tmpls = common_chat_templates_init(rt->model, std::string());
        if (tmpls == nullptr) {
            set_error(error_buf, error_buf_length, "Chat template parse failed: templates_init returned null");
            return nullptr;
        }
        common_chat_templates_inputs inputs;
        inputs.messages = common_chat_msgs_parse_oaicompat(msgs_json);
        inputs.tools = common_chat_tools_parse_oaicompat(tools_json_value);
        inputs.add_generation_prompt = true;
        inputs.use_jinja = true;
        inputs.enable_thinking = (enable_thinking != 0);

        common_chat_params params = common_chat_templates_apply(tmpls.get(), inputs);
        const std::string & rendered = params.prompt;

        char * result = static_cast<char *>(std::malloc(rendered.size() + 1));
        if (result == nullptr) {
            set_error(error_buf, error_buf_length, "out of memory");
            return nullptr;
        }
        std::memcpy(result, rendered.data(), rendered.size());
        result[rendered.size()] = '\0';
        return result;
    } catch (const std::exception & e) {
        set_error(error_buf, error_buf_length,
                  std::string("Chat template render failed: ") + e.what());
        return nullptr;
    }
}

char * lllm_parse_assistant_turn(
    lllm_runtime * rt,
    const char *   assistant_output,
    char *         error_buf,
    int32_t        error_buf_length
) {
    if (rt == nullptr || rt->model == nullptr) {
        set_error(error_buf, error_buf_length, "Runtime is not loaded.");
        return nullptr;
    }
    if (assistant_output == nullptr) {
        set_error(error_buf, error_buf_length, "assistant_output: NULL");
        return nullptr;
    }
    if (rt->chat_template.empty()) {
        set_error(error_buf, error_buf_length, "Model is missing chat template metadata");
        return nullptr;
    }

    try {
        common_chat_templates_ptr tmpls = common_chat_templates_init(rt->model, std::string());
        if (tmpls == nullptr) {
            set_error(error_buf, error_buf_length, "Chat template parse failed: templates_init returned null");
            return nullptr;
        }

        // common_chat_templates_apply runs the model's Jinja template; Gemma 4's
        // template dereferences messages[0]['role'] unconditionally, so a fully
        // empty inputs.messages crashes. We also pass a placeholder tool so
        // the format detector picks the PEG variant instead of CONTENT_ONLY
        // (without tools the template emits plain prose and the parser falls
        // back to content-only). The resulting `chat_params.prompt` is discarded.
        common_chat_templates_inputs inputs;
        inputs.messages = common_chat_msgs_parse_oaicompat(
            nlohmann::ordered_json::parse(R"([{"role":"user","content":""}])"));
        inputs.tools = common_chat_tools_parse_oaicompat(
            nlohmann::ordered_json::parse(
                R"([{"type":"function","function":{"name":"_lllm_format_probe","description":"format detection probe","parameters":{"type":"object","properties":{}}}}])"));
        inputs.add_generation_prompt = true;
        inputs.use_jinja = true;
        common_chat_params chat_params = common_chat_templates_apply(tmpls.get(), inputs);

        // common_chat_parser_params(const common_chat_params&) copies only
        // `format` and `generation_prompt`. For PEG formats the parse path
        // dispatches through common_chat_peg_parse, which takes the arena as
        // a separate argument — common_chat_params.parser is the serialized
        // arena (produced by common_peg_arena::save).
        common_chat_parser_params parser_params(chat_params);
        parser_params.parse_tool_calls = true;
        parser_params.reasoning_format = default_reasoning_format();

        common_chat_msg parsed;
        if (chat_params.format == COMMON_CHAT_FORMAT_CONTENT_ONLY || chat_params.parser.empty()) {
            parsed = common_chat_parse(std::string(assistant_output), false, parser_params);
        } else {
            common_peg_arena arena = common_peg_arena::from_json(
                nlohmann::json::parse(chat_params.parser));
            parsed = common_chat_peg_parse(arena, std::string(assistant_output), false, parser_params);
        }
        return serialize_parsed_to_c_string(parsed, error_buf, error_buf_length);
    } catch (const std::exception & e) {
        set_error(error_buf, error_buf_length, std::string("Assistant turn parse failed: ") + e.what());
        return nullptr;
    }
}

int32_t lllm_count_tokens(lllm_runtime* rt, const char* text, char* error_buf, int32_t error_buf_length) {
    if (rt == nullptr || rt->vocab == nullptr) {
        set_error(error_buf, error_buf_length, "Runtime is not loaded.");
        return -1;
    }
    if (text == nullptr) {
        set_error(error_buf, error_buf_length, "text: NULL");
        return -2;
    }

    std::lock_guard<std::mutex> guard(rt->mutex);

    std::vector<llama_token> tokens;
    std::string error;
    if (!tokenize(rt->vocab, std::string(text), tokens, error)) {
        set_error(error_buf, error_buf_length, error);
        return -3;
    }

    return static_cast<int32_t>(tokens.size());
}

int32_t lllm_runtime_generate_v2(
    lllm_runtime *           rt,
    const char *             prompt,
    lllm_sampler_params      params,
    const char *             grammar_gbnf,
    const char * const *     stop_sequences,
    lllm_token_callback_v2   callback,
    void *                   user_data,
    char *                   error_buf, int32_t error_buf_length
) {
    if (rt == nullptr || rt->context == nullptr || rt->vocab == nullptr) {
        set_error(error_buf, error_buf_length, "Runtime is not loaded.");
        return -1;
    }
    std::lock_guard<std::mutex> guard(rt->mutex);
    llama_memory_clear(llama_get_memory(rt->context), true);

    std::vector<llama_token> tokens;
    std::string err;
    if (!tokenize(rt->vocab, std::string(prompt == nullptr ? "" : prompt), tokens, err)) {
        set_error(error_buf, error_buf_length, err);
        return -2;
    }

    llama_batch batch = llama_batch_get_one(tokens.data(), static_cast<int32_t>(tokens.size()));
    if (llama_decode(rt->context, batch) != 0) {
        set_error(error_buf, error_buf_length, "Failed to decode prompt.");
        return -3;
    }

    llama_sampler_chain_params sp = llama_sampler_chain_default_params();
    sp.no_perf = true;
    llama_sampler * sampler = llama_sampler_chain_init(sp);

    int32_t  top_k   = params.top_k > 0 ? params.top_k : 64;
    float    top_p   = params.top_p > 0.0f ? params.top_p : 0.95f;
    float    min_p   = params.min_p >= 0.0f ? params.min_p : 0.05f;
    float    temp    = params.temperature > 0.0f ? params.temperature : 0.7f;
    float    rep_pen = params.repeat_penalty > 0.0f ? params.repeat_penalty : 1.0f;
    uint32_t seed    = params.seed != 0 ? params.seed : LLAMA_DEFAULT_SEED;
    int32_t  limit   = params.max_tokens > 0 ? params.max_tokens : 512;

    if (rep_pen != 1.0f) {
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(64, rep_pen, 0.0f, 0.0f));
    }
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(top_k));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(top_p, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_min_p(min_p, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(temp));
    if (grammar_gbnf != nullptr && grammar_gbnf[0] != '\0') {
        llama_sampler * g = llama_sampler_init_grammar(rt->vocab, grammar_gbnf, "root");
        if (g == nullptr) {
            llama_sampler_free(sampler);
            set_error(error_buf, error_buf_length, "Grammar parse failed");
            return -5;
        }
        llama_sampler_chain_add(sampler, g);
    }
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed));

    std::vector<std::string> stops;
    if (stop_sequences != nullptr) {
        for (const char * const * p = stop_sequences; *p != nullptr; ++p) {
            std::string s = *p;
            if (!s.empty()) stops.push_back(std::move(s));
        }
    }
    std::string emitted;

    int32_t produced = 0;
    for (; produced < limit; produced += 1) {
        llama_token next_token = llama_sampler_sample(sampler, rt->context, -1);
        if (llama_vocab_is_eog(rt->vocab, next_token)) break;
        std::string piece = token_to_string(rt->vocab, next_token);

        bool cancelled = false;
        if (callback != nullptr && !piece.empty()) {
            if (callback(piece.c_str(), user_data) != 0) cancelled = true;
        }
        if (cancelled) { produced += 1; break; }

        emitted.append(piece);
        bool stop_matched = false;
        for (auto const & s : stops) {
            size_t look = std::min(emitted.size(), s.size() + piece.size());
            size_t from = emitted.size() - look;
            if (emitted.find(s, from) != std::string::npos) { stop_matched = true; break; }
        }
        if (stop_matched) { if (produced < limit) produced += 1; break; }

        llama_batch nb = llama_batch_get_one(&next_token, 1);
        if (llama_decode(rt->context, nb) != 0) {
            llama_sampler_free(sampler);
            set_error(error_buf, error_buf_length, "Failed while generating response.");
            return -4;
        }
    }

    llama_sampler_free(sampler);
    return produced;
}

void lllm_string_free(char * s) {
    if (s != nullptr) {
        std::free(s);
    }
}
