//! The only way out of a skill's container: requests the script writes on stdout, served here.
//!
//! HTTP goes only to the hosts the skill declared (and the user agreed to), over HTTPS, without
//! redirects, and is logged and cached. Chain reads go through the wallet's own RPC, limited to
//! a fixed set of read-only methods. Nothing here can sign or send.

use std::{
    collections::{BTreeMap, HashMap},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use alloy_dyn_abi::{FunctionExt, JsonAbiExt, Specifier};
use alloy_json_abi::Function;
use alloy_primitives::{Address, hex};
use reqwest::Url;
use serde_json::{Value, json};

use super::abi;

/// The largest HTTP body a script is given; DefiLlama's full pool list is ~12 MB.
pub const MAX_BODY: usize = 16 * 1024 * 1024;
/// The widest `eth_getLogs` block range a script may ask for.
pub const MAX_LOG_BLOCKS: u64 = 10_000;
const HTTP_TIMEOUT: Duration = Duration::from_secs(30);

/// Responses kept across calls and skills, keyed by URL.
pub type SharedCache = Arc<Mutex<HashMap<String, (Instant, String)>>>;
pub type Log = Arc<dyn Fn(String) + Send + Sync>;

pub struct HostConfig {
    /// For the log lines.
    pub skill: String,
    pub hosts: Vec<String>,
    /// URL prefix → how long a 200 response stays cached.
    pub cache: BTreeMap<String, Duration>,
    pub rpc: Option<Url>,
    /// Tests: canned answers instead of the network. Keys are `GET <url>`, `POST <url>` and
    /// `rpc <method> <params as JSON>`; an HTTP value may start with `status:<code>\n`.
    pub fixtures: Option<Arc<BTreeMap<String, String>>>,
    pub log: Log,
}

pub struct Host {
    config: HostConfig,
    cache: SharedCache,
    http: reqwest::Client,
}

impl Host {
    pub fn new(config: HostConfig, cache: SharedCache) -> Self {
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(HTTP_TIMEOUT)
            .build()
            .expect("a client with static settings builds");
        Self {
            config,
            cache,
            http,
        }
    }

    /// Answers one request line from a script. Always returns a reply carrying the same `id`.
    pub async fn handle(&self, request: &Value) -> Value {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let kind = request.get("type").and_then(Value::as_str).unwrap_or("");
        let answer = match kind {
            "http_get" => self.http(request, false).await,
            "http_post" => self.http(request, true).await,
            "eth_call" => self.eth_call(request).await,
            "call" => self.call(request).await,
            "eth_getLogs" => self.get_logs(request).await,
            "eth_chainId" => self.rpc("eth_chainId", json!([])).await.map(result),
            "eth_blockNumber" => self.rpc("eth_blockNumber", json!([])).await.map(result),
            "eth_getBalance" => match field(request, "address") {
                Ok(address) => self
                    .rpc("eth_getBalance", json!([address, "latest"]))
                    .await
                    .map(result),
                Err(e) => Err(e),
            },
            other => Err(format!("`{other}` is not a host call skills may make")),
        };
        let mut reply = match answer {
            Ok(Value::Object(fields)) => Value::Object(fields),
            Ok(other) => json!({"result": other}),
            Err(error) => json!({"ok": false, "error": error}),
        };
        reply["type"] = json!("reply");
        reply["id"] = id;
        if reply.get("ok").is_none() {
            reply["ok"] = json!(true);
        }
        reply
    }

    async fn http(&self, request: &Value, post: bool) -> Result<Value, String> {
        let url = field(request, "url")?;
        let parsed: Url = url.parse().map_err(|_| format!("`{url}` is not a URL"))?;
        if parsed.scheme() != "https" {
            return Err(format!("{url}: only https URLs are allowed"));
        }
        let host = parsed.host_str().unwrap_or_default().to_owned();
        if !self.config.hosts.contains(&host) {
            return Err(format!(
                "{host} is not one of this skill's declared hosts ({})",
                self.config.hosts.join(", ")
            ));
        }
        let ttl = self
            .config
            .cache
            .iter()
            .find(|(prefix, _)| url.starts_with(prefix.as_str()))
            .map(|(_, ttl)| *ttl);
        if !post
            && let Some(ttl) = ttl
            && let Some((at, body)) = self.cache.lock().expect("cache lock").get(url)
            && at.elapsed() < ttl
        {
            return Ok(json!({"status": 200, "body": body}));
        }
        let method = if post { "POST" } else { "GET" };
        (self.config.log)(format!(
            "{} {method} {host}{}",
            self.config.skill,
            parsed.path()
        ));
        let (status, body) = match &self.config.fixtures {
            Some(fixtures) => {
                let canned = fixtures
                    .get(&format!("{method} {url}"))
                    .ok_or_else(|| format!("no fixture for {method} {url}"))?;
                match canned
                    .strip_prefix("status:")
                    .and_then(|rest| rest.split_once('\n'))
                {
                    Some((code, body)) => (code.parse().unwrap_or(500), body.to_owned()),
                    None => (200, canned.clone()),
                }
            }
            None => {
                self.fetch(&parsed, post.then(|| request.get("body")))
                    .await?
            }
        };
        if status == 200 && ttl.is_some() && !post {
            self.cache
                .lock()
                .expect("cache lock")
                .insert(url.to_owned(), (Instant::now(), body.clone()));
        }
        Ok(json!({"status": status, "body": body}))
    }

    async fn fetch(
        &self,
        url: &Url,
        body: Option<Option<&Value>>,
    ) -> Result<(u16, String), String> {
        let request = match body {
            Some(body) => {
                let text = match body {
                    Some(Value::String(s)) => s.clone(),
                    Some(other) => other.to_string(),
                    None => String::new(),
                };
                self.http
                    .post(url.clone())
                    .header("content-type", "application/json")
                    .body(text)
            }
            None => self.http.get(url.clone()),
        };
        let mut response = request.send().await.map_err(|e| format!("{url}: {e}"))?;
        let status = response.status().as_u16();
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|e| format!("{url}: {e}"))? {
            bytes.extend_from_slice(&chunk);
            if bytes.len() > MAX_BODY {
                return Err(format!("{url}: the response is over 16 MiB"));
            }
        }
        Ok((status, String::from_utf8_lossy(&bytes).into_owned()))
    }

    async fn rpc(&self, method: &str, params: Value) -> Result<Value, String> {
        if let Some(fixtures) = &self.config.fixtures {
            let key = format!("rpc {method} {params}");
            let canned = fixtures
                .get(&key)
                .ok_or_else(|| format!("no fixture for {key}"))?;
            return serde_json::from_str(canned).map_err(|e| format!("fixture {key}: {e}"));
        }
        let url = self
            .config
            .rpc
            .clone()
            .ok_or("no RPC endpoint: unlock a network first")?;
        let response: Value = self
            .http
            .post(url)
            .json(&json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))
            .send()
            .await
            .map_err(|e| format!("{method}: {e}"))?
            .json()
            .await
            .map_err(|e| format!("{method}: {e}"))?;
        if let Some(error) = response.get("error") {
            return Err(format!("{method}: {error}"));
        }
        Ok(response.get("result").cloned().unwrap_or(Value::Null))
    }

    async fn eth_call(&self, request: &Value) -> Result<Value, String> {
        let to = address(field(request, "to")?)?;
        let data = field(request, "data")?;
        let block = request
            .get("block")
            .and_then(Value::as_str)
            .unwrap_or("latest");
        self.rpc(
            "eth_call",
            json!([{"to": format!("{to:#x}"), "data": data}, block]),
        )
        .await
        .map(result)
    }

    /// `eth_call` with the encoding done here: `function` is a human-readable signature with
    /// its return types, `args` the inputs as JSON; the result is the decoded outputs.
    async fn call(&self, request: &Value) -> Result<Value, String> {
        let to = address(field(request, "to")?)?;
        let signature = field(request, "function")?;
        let function =
            Function::parse(signature).map_err(|e| format!("function `{signature}`: {e}"))?;
        let args = request
            .get("args")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if args.len() != function.inputs.len() {
            return Err(format!(
                "{} takes {} arguments, got {}",
                function.name,
                function.inputs.len(),
                args.len()
            ));
        }
        let values = function
            .inputs
            .iter()
            .zip(&args)
            .map(|(param, arg)| {
                let ty = param.resolve().map_err(|e| format!("{}: {e}", param.ty))?;
                abi::coerce(&ty, arg)
            })
            .collect::<Result<Vec<_>, _>>()?;
        let data = function
            .abi_encode_input(&values)
            .map_err(|e| format!("{}: {e}", function.name))?;
        let block = request
            .get("block")
            .and_then(Value::as_str)
            .unwrap_or("latest");
        let raw = self
            .rpc(
                "eth_call",
                json!([{"to": format!("{to:#x}"), "data": hex::encode_prefixed(&data)}, block]),
            )
            .await?;
        let raw = raw.as_str().ok_or("eth_call returned no data")?;
        let bytes = hex::decode(raw).map_err(|e| format!("eth_call returned bad hex: {e}"))?;
        let outputs = function
            .abi_decode_output(&bytes)
            .map_err(|e| format!("{}: cannot decode the result ({e})", function.name))?;
        Ok(json!({"result": outputs.iter().map(abi::to_json).collect::<Vec<_>>()}))
    }

    async fn get_logs(&self, request: &Value) -> Result<Value, String> {
        let filter = request.get("filter").ok_or("eth_getLogs needs a filter")?;
        let block = |key: &str| {
            filter
                .get(key)
                .and_then(Value::as_str)
                .and_then(|s| u64::from_str_radix(s.trim_start_matches("0x"), 16).ok())
                .ok_or_else(|| format!("eth_getLogs needs a hex {key}"))
        };
        let (from, to) = (block("fromBlock")?, block("toBlock")?);
        if to < from || to - from > MAX_LOG_BLOCKS {
            return Err(format!(
                "eth_getLogs may span at most {MAX_LOG_BLOCKS} blocks"
            ));
        }
        self.rpc("eth_getLogs", json!([filter])).await.map(result)
    }
}

fn result(value: Value) -> Value {
    json!({ "result": value })
}

fn field<'a>(request: &'a Value, key: &str) -> Result<&'a str, String> {
    request
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("missing `{key}`"))
}

fn address(text: &str) -> Result<Address, String> {
    text.parse()
        .map_err(|_| format!("`{text}` is not an address"))
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex as StdMutex;

    use serde_json::json;

    use super::*;

    fn host(fixtures: &[(&str, &str)]) -> (Host, Arc<StdMutex<Vec<String>>>) {
        let log = Arc::new(StdMutex::new(Vec::new()));
        let sink = log.clone();
        let host = Host::new(
            HostConfig {
                skill: "demo".into(),
                hosts: vec!["yields.llama.fi".into()],
                cache: BTreeMap::from([(
                    "https://yields.llama.fi/pools".to_owned(),
                    Duration::from_secs(60),
                )]),
                rpc: None,
                fixtures: Some(Arc::new(
                    fixtures
                        .iter()
                        .map(|(k, v)| (k.to_string(), v.to_string()))
                        .collect(),
                )),
                log: Arc::new(move |line| sink.lock().unwrap().push(line)),
            },
            SharedCache::default(),
        );
        (host, log)
    }

    #[tokio::test]
    async fn only_declared_https_hosts_are_reachable() {
        let (host, _) = host(&[]);
        let reply = host
            .handle(&json!({"type": "http_get", "id": 1, "url": "https://evil.example/x"}))
            .await;
        assert_eq!(reply["ok"], false);
        assert!(reply["error"].as_str().unwrap().contains("evil.example"));
        assert_eq!(reply["id"], 1);
        let reply = host
            .handle(&json!({"type": "http_get", "id": 2, "url": "http://yields.llama.fi/pools"}))
            .await;
        assert_eq!(reply["ok"], false);
        assert!(reply["error"].as_str().unwrap().contains("https"));
    }

    #[tokio::test]
    async fn a_cached_response_is_fetched_once() {
        let (host, log) = host(&[("GET https://yields.llama.fi/pools", "{\"data\":[]}")]);
        for id in 1..=2 {
            let reply = host
                .handle(
                    &json!({"type": "http_get", "id": id, "url": "https://yields.llama.fi/pools"}),
                )
                .await;
            assert_eq!(reply["ok"], true, "{reply}");
            assert_eq!(reply["status"], 200);
            assert_eq!(reply["body"], "{\"data\":[]}");
        }
        assert_eq!(log.lock().unwrap().len(), 1, "{:?}", log.lock().unwrap());
        assert!(log.lock().unwrap()[0].contains("demo GET yields.llama.fi/pools"));
    }

    #[tokio::test]
    async fn a_fixture_can_answer_with_a_status() {
        let (host, _) = host(&[(
            "GET https://yields.llama.fi/chart/x",
            "status:429\nslow down",
        )]);
        let reply = host
            .handle(&json!({"type": "http_get", "id": 1, "url": "https://yields.llama.fi/chart/x"}))
            .await;
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["status"], 429);
        assert_eq!(reply["body"], "slow down");
    }

    #[tokio::test]
    async fn call_encodes_and_decodes_through_eth_call() {
        // balanceOf(0x…bEEF) → 1_000_000
        let data = "0x70a08231000000000000000000000000000000000000000000000000000000000000beef";
        let to = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";
        let key = format!(r#"rpc eth_call [{{"data":"{data}","to":"{to}"}},"latest"]"#);
        let result = "\"0x00000000000000000000000000000000000000000000000000000000000f4240\"";
        let (host, _) = host(&[(&key, result)]);
        let reply = host
            .handle(&json!({
                "type": "call", "id": 7, "to": to,
                "function": "function balanceOf(address owner) view returns (uint256)",
                "args": ["0x000000000000000000000000000000000000bEEF"]
            }))
            .await;
        assert_eq!(reply["ok"], true, "{reply}");
        assert_eq!(reply["result"], json!(["1000000"]));
    }

    #[tokio::test]
    async fn unknown_requests_and_wide_log_ranges_are_refused() {
        let (host, _) = host(&[]);
        let reply = host
            .handle(&json!({"type": "eth_sendRawTransaction", "id": 1}))
            .await;
        assert_eq!(reply["ok"], false);
        let reply = host
            .handle(&json!({"type": "eth_getLogs", "id": 2, "filter": {"fromBlock": "0x0", "toBlock": "0x10000"}}))
            .await;
        assert_eq!(reply["ok"], false);
        assert!(reply["error"].as_str().unwrap().contains("10000"));
    }

    #[test]
    fn decoded_values_become_plain_json() {
        use alloy_dyn_abi::DynSolValue;
        use alloy_primitives::{U256, address};
        let value = DynSolValue::Tuple(vec![
            DynSolValue::Uint(U256::from(5u8), 256),
            DynSolValue::Address(address!("0x000000000000000000000000000000000000bEEF")),
            DynSolValue::Bool(true),
        ]);
        assert_eq!(
            abi::to_json(&value),
            json!(["5", "0x000000000000000000000000000000000000bEEF", true])
        );
    }
}
