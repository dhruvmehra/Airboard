# AI Cleanup Server Recipes

Airboard's AI cleanup (grammar, paragraphs, spoken lists → bullet/numbered
lists) works with **any OpenAI-compatible endpoint**. Open the menu-bar
popover → gear next to "AI cleanup", enter a Server URL + Model + API key,
hit **Test connection**, done. With no server configured, Airboard still
removes filler words locally — nothing is ever sent anywhere.

The API key is stored in the macOS Keychain. Dictated text is sent to the
configured server only (over HTTPS), only in normal dictation mode, only
while the AI cleanup toggle is on.

## 1. OpenRouter / OpenAI (fastest — ~2 minutes)

1. Create an API key at https://openrouter.ai/keys (or platform.openai.com).
2. In Airboard's cleanup settings:
   - Server URL: `https://openrouter.ai/api` (or `https://api.openai.com`)
   - Model: `qwen/qwen3-30b-a3b-instruct` (or any small fast model)
   - API key: your key
3. Test connection.

Cost at typical dictation volume is a few dollars/month per active user.

## 2. AWS Bedrock (teams)

Keeps transcripts inside your AWS account/region; inputs are not used for
model training. Issue **one API key per teammate** so keys are individually
revocable.

1. In the AWS console, enable access to your chosen model in Bedrock
   (a Qwen3-class or comparable small instruct model).
2. Create a Bedrock API key per user (Bedrock → API keys), or use IAM users
   with the `AmazonBedrockLimitedAccess` policy.
3. In Airboard's cleanup settings use Bedrock's OpenAI-compatible endpoint
   for your region (check the current AWS docs for the exact path — it has
   the shape `https://bedrock-runtime.<region>.amazonaws.com/openai`):
   - Server URL: the endpoint above
   - Model: the Bedrock model ID
   - API key: that user's key
4. Test connection. If your chosen model isn't served via the
   OpenAI-compatible endpoint, front Bedrock with the LiteLLM proxy below —
   it translates for every Bedrock model.

Want per-user usage dashboards, spend caps, or to swap models without
touching 15 laptops? Put a [LiteLLM proxy](https://docs.litellm.ai) (runs on
a $7/mo micro instance) in front of Bedrock and point Airboard at the proxy
instead — Airboard doesn't change, only the URL does.

## 3. Self-hosted (privacy-max / $0 per token)

**Ollama on any spare Mac (or your own machine):**

    ollama pull qwen3:8b
    OLLAMA_HOST=0.0.0.0 ollama serve

- Server URL: `http://<that-machine>.local:11434`
- Model: `qwen3:8b`
- API key: leave empty

**vLLM on a GPU box** (e.g. AWS g6.xlarge, ~$0.80/hr — stoppable off-hours):

    pip install vllm
    vllm serve Qwen/Qwen3-30B-A3B-Instruct-2507 --quantization awq --api-key <team-key>

- Server URL: `http://<host>:8000` (put TLS in front for internet exposure)
  Note: macOS App Transport Security blocks plain `http://` to qualified
  domain names — bare IPs, `.local`, and single-label hostnames work, but for
  a real domain you must put TLS in front.
- Model: `Qwen/Qwen3-30B-A3B-Instruct-2507`
- API key: the `--api-key` value

Note: exact model names/flags evolve — check each tool's current docs.
