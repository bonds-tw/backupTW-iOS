#!/usr/bin/env node

/**
 * Obtains a TW FidO (行動自然人憑證) signature over the relying-party APP_ID and
 * writes the resulting cert + signed_response — the inputs the OpenAC circuits
 * need.
 *
 * Two request modes, because they behave very differently for the user:
 *
 *   push (default) — SP-API-ATH-03 requestAthOrSignPush. The MOICA app raises
 *     the prompt on its own. Nothing to open, no second device needed.
 *
 *   app2app        — SP-API-ATH-01 getSpTicket with op_mode=APP2APP. Prints a
 *     mobilemoica:// deep link that has to be opened ON THE PHONE. Nothing
 *     appears in the app until you do. This is the mode a native iOS app uses;
 *     from a terminal, prefer push.
 *
 * Both then poll SP-API-ATH-02 getAthOrSignResult for the outcome.
 *
 * Reference: 行動自然人憑證應用程式介面規格書 v2.9 (MOI_CA_DEV_API).
 */

import { Buffer } from "node:buffer";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

// zkID derives the nullifier from APP_ID + cardholder key, so this string is a
// relying-party namespace, not a cosmetic label. It is signed as the TBS and
// must match the APP_ID the verifier is configured with.
const DEFAULT_APP_ID = "e775f2805fb993e05a208dbff15d1c1";
const DEFAULT_HINT = "有備而來：身分證明簽章";
const DEFAULT_OUTPUT = path.join(os.homedir(), ".config", "secrets", "tw_fido_sign_response.json");

const API_BASE_URLS = {
  prod: "https://fidoapi.moi.gov.tw",
  uat: "https://fido-test.moi.gov.tw",
};

// The result endpoint reports "not signed yet" as an error code rather than an
// empty success, so these are progress, not failure.
const PENDING_CODES = new Set([
  "20002",
  "20003",
  "SP-API-ATH-02-SPTKTID_TXNLOG_NF",
  "SPTKTID_TXNLOG_NF",
]);

const USAGE = `
用法：
  source ~/.config/secrets/twfido-sim.env
  node scripts/twfido-sign.mjs --id-num A123456789

選項：
  --id-num <身分證字號>     必填。
  --mode <push|app2app>     預設 push。push 會讓行動自然人憑證 App 主動跳出；
                            app2app 只印出深連結，要自己在手機上打開。
  --device <裝置別名>        只推播到這台裝置；不給則推播到所有已綁定裝置。
  --env <prod|uat>          預設 prod（行憑正式環境）。
  --base-url <url>          覆寫 --env。
  --app-id <31 字元 hex>     預設 ${DEFAULT_APP_ID}
  --hint <文字>              App 上顯示的提示訊息。
  --sign-type <PKCS#1|PKCS#7|RAW>   預設 PKCS#1（zkID 電路只吃這個）。
  --time-limit <30-600>     預設 600 秒。
  --rtn-url <url>           app2app 專用，簽完導回的位置。
  --output <path>           預設 ${DEFAULT_OUTPUT}
  --timeout-seconds <n>     預設 600。
  --poll-interval <n>       預設 4（規格書建議下限）。
  --no-poll                 只建立請求，不等結果。
  -h, --help

環境變數：
  FIDO_SP_SERVICE_ID        SP 服務識別碼
  FIDO_AES_KEY_BASE64       AES-256 金鑰（base64）。FIDO_AES_KEY 亦可。
`;

function parseArgs(argv) {
  const args = {
    mode: "push",
    env: "prod",
    appId: DEFAULT_APP_ID,
    hint: DEFAULT_HINT,
    signType: "PKCS#1",
    timeLimit: 600,
    rtnUrl: "https://bonds.tw/",
    rtnVal: "",
    output: DEFAULT_OUTPUT,
    timeoutSeconds: 600,
    pollInterval: 4,
    poll: true,
  };
  const take = (i, flag) => {
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("--")) throw new Error(`${flag} 缺少值`);
    return v;
  };
  for (let i = 0; i < argv.length; i += 1) {
    switch (argv[i]) {
      case "-h": case "--help": args.help = true; break;
      case "--id-num": args.idNum = take(i, argv[i]); i += 1; break;
      case "--mode": args.mode = take(i, argv[i]); i += 1; break;
      case "--device": args.device = take(i, argv[i]); i += 1; break;
      case "--env": args.env = take(i, argv[i]); i += 1; break;
      case "--base-url": args.baseUrl = take(i, argv[i]); i += 1; break;
      case "--app-id": args.appId = take(i, argv[i]); i += 1; break;
      case "--hint": args.hint = take(i, argv[i]); i += 1; break;
      case "--sign-type": args.signType = take(i, argv[i]); i += 1; break;
      case "--time-limit": args.timeLimit = Number(take(i, argv[i])); i += 1; break;
      case "--rtn-url": args.rtnUrl = take(i, argv[i]); i += 1; break;
      case "--output": args.output = take(i, argv[i]); i += 1; break;
      case "--timeout-seconds": args.timeoutSeconds = Number(take(i, argv[i])); i += 1; break;
      case "--poll-interval": args.pollInterval = Number(take(i, argv[i])); i += 1; break;
      case "--no-poll": args.poll = false; break;
      default: throw new Error(`未知選項 ${argv[i]}`);
    }
  }
  return args;
}

function validate(args) {
  if (!args.idNum) throw new Error("--id-num 為必填");
  if (!["push", "app2app"].includes(args.mode)) throw new Error("--mode 只能是 push 或 app2app");
  if (!["PKCS#1", "PKCS#7", "RAW"].includes(args.signType)) throw new Error("--sign-type 不合法");
  if (!API_BASE_URLS[args.env] && !args.baseUrl) throw new Error("--env 只能是 prod 或 uat");
  // The circuits treat APP_ID as fixed-width; a wrong length fails much later,
  // inside proof generation, where the cause is far harder to see.
  const bytes = Buffer.byteLength(args.appId, "utf8");
  if (bytes !== 31) throw new Error(`APP_ID 必須是 31 bytes，目前 ${bytes}`);
  if (!Number.isFinite(args.timeLimit) || args.timeLimit < 30 || args.timeLimit > 600) {
    throw new Error("--time-limit 必須介於 30 到 600");
  }
  if (!Number.isFinite(args.pollInterval) || args.pollInterval < 4) {
    throw new Error("--poll-interval 不得小於 4（規格書建議）");
  }
}

/**
 * sp_checksum = hex( IV ‖ AES-256-GCM(SHA-256(payload) as lowercase hex text) ‖ tag )
 *
 * The plaintext is the 64-character hex *string*, not the 32 raw digest bytes.
 * The spec's own .NET sample uses an all-zero IV; a random one is used here
 * instead. The IV travels in the clear as the first 12 bytes either way, and
 * reusing a fixed nonce across messages under one key is exactly what GCM must
 * not do. The ATH-01 example in the spec is itself random-IV, so the server
 * accepts both.
 */
function spChecksum(payload, aesKeyBase64) {
  const key = Buffer.from(aesKeyBase64, "base64");
  if (key.length !== 32) throw new Error(`AES 金鑰解碼後必須是 32 bytes，目前 ${key.length}`);
  const digestHex = crypto.createHash("sha256").update(payload, "utf8").digest("hex");
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, iv, { authTagLength: 16 });
  const ciphertext = Buffer.concat([cipher.update(Buffer.from(digestHex, "utf8")), cipher.final()]);
  return Buffer.concat([iv, ciphertext, cipher.getAuthTag()]).toString("hex");
}

function decodeSpTicket(spTicket) {
  const dot = spTicket.lastIndexOf(".");
  if (dot < 0) throw new Error("sp_ticket 沒有 payload 分隔符");
  const payload = JSON.parse(Buffer.from(spTicket.slice(0, dot), "base64url").toString("utf8"));
  if (!payload.transaction_id || !payload.sp_ticket_id) {
    throw new Error("sp_ticket payload 缺少 transaction_id 或 sp_ticket_id");
  }
  return payload;
}

async function postJson(url, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json; charset=utf-8" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new Error(`HTTP ${res.status} from ${url}: ${text.slice(0, 400)}`);
  }
  if (!res.ok) throw new Error(`HTTP ${res.status} from ${url}: ${JSON.stringify(json)}`);
  return json;
}

function signInfo(args, signData) {
  const info = { sign_type: args.signType, sign_data: signData, tbs_encoding: "base64" };
  // RAW carries its own DigestInfo, so a hash algorithm would be meaningless.
  if (args.signType !== "RAW") info.hash_algorithm = "SHA256";
  return info;
}

/** SP-API-ATH-03 — the MOICA app raises the prompt itself. */
async function requestPush({ args, spServiceId, aesKey, baseUrl, signData }) {
  const transactionId = crypto.randomUUID();
  // device_user_def_desc participates in the checksum only when it is sent;
  // omitting it pushes to every device bound to this ID number.
  const parts = [transactionId, spServiceId, args.idNum];
  if (args.device) parts.push(args.device);
  parts.push("SIGN", args.hint, signData);

  const body = {
    transaction_id: transactionId,
    sp_service_id: spServiceId,
    sp_checksum: spChecksum(parts.join(""), aesKey),
    id_num: args.idNum,
    op_code: "SIGN",
    hint: args.hint,
    time_limit: args.timeLimit,
    sign_info: signInfo(args, signData),
  };
  if (args.device) body.device_user_def_desc = args.device;

  const json = await postJson(`${baseUrl}/moise/sp/requestAthOrSignPush`, body);
  if (json.error_code !== "0") {
    throw new Error(`requestAthOrSignPush 失敗：${json.error_code} ${json.error_message ?? ""}`.trim());
  }
  return { spTicket: json.result?.sp_ticket, deeplink: null };
}

/** SP-API-ATH-01 — returns a deep link that must be opened on the phone. */
async function requestAppToApp({ args, spServiceId, aesKey, baseUrl, signData }) {
  const transactionId = crypto.randomUUID();
  const payload = [transactionId, spServiceId, args.idNum, "SIGN", "APP2APP", args.hint, signData].join("");
  const body = {
    transaction_id: transactionId,
    id_num: args.idNum,
    op_code: "SIGN",
    op_mode: "APP2APP",
    sp_service_id: spServiceId,
    sp_checksum: spChecksum(payload, aesKey),
    hint: args.hint,
    time_limit: String(args.timeLimit),
    sign_info: signInfo(args, signData),
  };
  const json = await postJson(`${baseUrl}/moise/sp/getSpTicket`, body);
  if (json.error_code !== "0") {
    throw new Error(`getSpTicket 失敗：${json.error_code} ${json.error_message ?? ""}`.trim());
  }
  const spTicket = json.result?.sp_ticket;
  const url = new URL("mobilemoica://moica.moi.gov.tw/a2a/verifySign");
  url.searchParams.set("sp_ticket", spTicket);
  url.searchParams.set("rtn_url", Buffer.from(args.rtnUrl, "utf8").toString("base64url"));
  url.searchParams.set("rtn_val", Buffer.from(args.rtnVal, "utf8").toString("base64url"));
  return { spTicket, deeplink: url.toString() };
}

/** SP-API-ATH-02 */
async function fetchResult({ ticket, spServiceId, aesKey, baseUrl }) {
  const payload = [ticket.transaction_id, spServiceId, ticket.sp_ticket_id].join("");
  return postJson(`${baseUrl}/moise/sp/getAthOrSignResult`, {
    transaction_id: ticket.transaction_id,
    sp_service_id: spServiceId,
    sp_checksum: spChecksum(payload, aesKey),
    sp_ticket_id: ticket.sp_ticket_id,
  });
}

async function poll({ args, ticket, spServiceId, aesKey, baseUrl }) {
  const deadline = Date.now() + args.timeoutSeconds * 1000;
  let announced = false;
  while (Date.now() < deadline) {
    const json = await fetchResult({ ticket, spServiceId, aesKey, baseUrl });
    if (json.error_code === "0") return json;
    if (!PENDING_CODES.has(json.error_code)) {
      throw new Error(`getAthOrSignResult 失敗：${json.error_code} ${json.error_message ?? ""}`.trim());
    }
    if (!announced) {
      console.log(`等待簽章中（狀態 ${json.error_code}），請在手機上完成。`);
      announced = true;
    }
    await new Promise((r) => setTimeout(r, args.pollInterval * 1000));
  }
  throw new Error(`等待逾時（${args.timeoutSeconds} 秒）`);
}

async function writeResult(output, json) {
  if (!json.result?.cert || !json.result?.signed_response) {
    throw new Error("簽章結果缺少 result.cert 或 result.signed_response");
  }
  await fs.mkdir(path.dirname(output), { recursive: true, mode: 0o700 });
  await fs.writeFile(output, `${JSON.stringify(json, null, 2)}\n`, { mode: 0o600 });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return void console.log(USAGE);
  validate(args);

  const spServiceId = process.env.FIDO_SP_SERVICE_ID;
  const aesKey = process.env.FIDO_AES_KEY_BASE64 ?? process.env.FIDO_AES_KEY;
  if (!spServiceId) throw new Error("缺少環境變數 FIDO_SP_SERVICE_ID");
  if (!aesKey) throw new Error("缺少環境變數 FIDO_AES_KEY_BASE64");

  const baseUrl = args.baseUrl ?? API_BASE_URLS[args.env];
  const signData = Buffer.from(args.appId, "utf8").toString("base64");

  console.log(`模式      ${args.mode}`);
  console.log(`API       ${baseUrl}`);
  console.log(`APP_ID    ${args.appId}`);
  console.log(`簽章類型  ${args.signType}`);
  console.log(`推播對象  ${args.device ?? "所有已綁定裝置"}`);
  console.log("");

  const request = args.mode === "push" ? requestPush : requestAppToApp;
  const { spTicket, deeplink } = await request({ args, spServiceId, aesKey, baseUrl, signData });
  const ticket = decodeSpTicket(spTicket);
  console.log(`sp_ticket_id  ${ticket.sp_ticket_id}`);

  if (deeplink) {
    console.log("");
    console.log("app2app 模式不會主動通知。請把下面這條連結傳到手機上打開：");
    console.log(deeplink);
  } else {
    console.log("");
    console.log("已送出推播，請看手機上的行動自然人憑證 App。");
    console.log("若完全沒有動靜，通常是：該身分證字號尚未在任何裝置開通、");
    console.log("App 的通知權限被關閉、或 --device 別名打錯。");
  }
  console.log("");

  if (!args.poll) return void console.log("--no-poll 已指定，不等待結果。");

  const signed = await poll({ args, ticket, spServiceId, aesKey, baseUrl });
  await writeResult(args.output, signed);
  console.log(`簽章完成，已寫入 ${args.output}`);
  console.log("（內含身分證字號與憑證資料，不可進 git、不可貼進 PR）");
}

main().catch((error) => {
  console.error(`錯誤：${error.message}`);
  process.exitCode = 1;
});
