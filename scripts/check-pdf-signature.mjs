#!/usr/bin/env node
//
// 問一份 PDF 有沒有文件級簽章，只回答這件事。
//
// 用法：
//   node scripts/check-pdf-signature.mjs <某個.pdf 或 某個.zip>
//
// 這支腳本刻意只輸出「信封」層級的事實——有無簽章、SubFilter、份數、
// 有無 ByteRange。它不解密、不抽文字、不印出文件裡的任何一個字。
// 掃到的位元組留在記憶體裡，什麼都不寫出去。
//
// 為什麼不用解密也能回答：PDF 的標準加密（本檔的情形是用身分證字號當
// 密碼）只加密「字串」與「串流」，不加密名稱物件與字典結構。也就是說
// /Type /Sig、/SubFilter、/ByteRange 這些鍵在加密檔裡仍然是明文，
// 而放 PKCS#7 的 /Contents 是字串、會被加密——但我們不需要它。
//
// 這與 app 內 PDFSignatureScan 的判斷邏輯一致，兩邊答案應該相同。

import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const target = process.argv[2];
if (!target) {
  console.error("用法：node scripts/check-pdf-signature.mjs <某個.pdf 或 某個.zip>");
  process.exit(2);
}

/** 從 zip 取出裡面唯一那份 PDF 的位元組（不需要密碼——zip 本身沒加密，加密的是 PDF）。 */
function pdfBytesFrom(path) {
  if (!path.toLowerCase().endsWith(".zip")) return readFileSync(path);

  const dir = mkdtempSync(join(tmpdir(), "pdfsig-"));
  try {
    execFileSync("unzip", ["-qq", "-o", path, "-d", dir], { stdio: ["ignore", "ignore", "pipe"] });
    const pdfs = readdirSync(dir).filter((n) => n.toLowerCase().endsWith(".pdf"));
    if (pdfs.length !== 1) {
      throw new Error(`zip 裡有 ${pdfs.length} 份 PDF，預期剛好一份`);
    }
    return readFileSync(join(dir, pdfs[0]));
  } finally {
    // 解出來的東西不留在磁碟上。
    rmSync(dir, { recursive: true, force: true });
  }
}

const bytes = pdfBytesFrom(target);

// latin1，不是 utf8：PDF 內文是夾著二進位串流的位元組湯，utf8 解碼會在
// 第一個非法序列就壞掉，那會把每一份真實文件都報成「沒有簽章」。
const text = bytes.toString("latin1");

const count = (re) => (text.match(re) ?? []).length;
const sigDicts = count(/\/Type\s*\/Sig\b/g);
const byteRanges = count(/\/ByteRange\s*\[/g);
const subFilters = [...new Set([...text.matchAll(/\/SubFilter\s*\/([A-Za-z0-9._-]+)/g)].map((m) => m[1]))];

// /Type 在規格裡是選用的，所以只有 /ByteRange 也算簽了。少報比多報危險：
// 一個假的「沒有簽章」會直接終結這個調查。
const isSigned = sigDicts > 0 || byteRanges > 0;

console.log();
console.log(`檔案      ${target}`);
console.log(`大小      ${bytes.length.toLocaleString()} bytes`);
console.log(`加密      ${/\/Encrypt\b/.test(text) ? "是（不影響本判斷）" : "否"}`);
console.log("─".repeat(56));
if (isSigned) {
  console.log(`結論      有文件級簽章`);
  console.log(`簽章字典  ${sigDicts} 份`);
  console.log(`ByteRange ${byteRanges} 個`);
  console.log(`SubFilter ${subFilters.length ? subFilters.join(", ") : "（未標示）"}`);
  console.log();
  console.log("→ 資料本身帶著信任根。zkpdf 這條路可行，且比行憑代簽更強：");
  console.log("  不需要持卡人每次出示都再簽一次。憑證設計應改用原始簽章。");
} else {
  console.log(`結論      沒有找到文件級簽章`);
  console.log();
  console.log("→ 行憑代簽（拿行憑去簽 MyData 的欄位事實）是正解，可以放心投入。");
}
console.log();
console.log("注意：這只回答「有沒有簽章」，沒有驗證簽章是否有效——");
console.log("      沒有做鏈結建構、沒有比對摘要、沒有查撤銷。");
console.log();
