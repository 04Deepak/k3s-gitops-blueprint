// Verify the SERVER half of object storage: can this pod, with the credentials it actually has,
// use the bucket? HeadBucket -> PutObject -> GetObject (bytes compared) -> DeleteObject.
//
// Run it from inside a pod, not from your laptop — different DNS, different egress address,
// possibly a different endpoint, so a laptop can pass while the cluster cannot reach the store.
//
//   kubectl -n NS cp templates/scripts/s3-verify.cjs POD:/tmp/s3-verify.cjs
//   kubectl -n NS exec POD -- sh -c 'NODE_PATH=/app/node_modules node /tmp/s3-verify.cjs'
//
// NODE_PATH, and the .cjs extension, are both load-bearing: a container with a read-only root
// filesystem forces you to run from /tmp, which is outside the app tree, so Node's resolver
// never walks up into node_modules. NODE_PATH fixes that for CommonJS and is IGNORED for ESM.
//
// This script passing does NOT mean uploads work. See s3-browser-verify.cjs.
const {
  S3Client, PutObjectCommand, GetObjectCommand, DeleteObjectCommand, HeadBucketCommand,
} = require("@aws-sdk/client-s3");

const need = ["S3_ENDPOINT", "S3_BUCKET", "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY"];
const missing = need.filter((k) => !process.env[k]);
if (missing.length) { console.log("MISSING: " + missing.join(", ")); process.exit(2); }
const placeholders = need.filter((k) => /REPLACE_ME|CHANGE_ME/i.test(process.env[k]));
if (placeholders.length) { console.log("STILL PLACEHOLDER: " + placeholders.join(", ")); process.exit(2); }

const bucket = process.env.S3_BUCKET;
const s3 = new S3Client({
  region: process.env.S3_REGION || "auto",
  endpoint: process.env.S3_ENDPOINT,
  // The bucket belongs in the PATH, not the endpoint hostname. Getting this wrong returns
  // SignatureDoesNotMatch, which reads like a bad secret key.
  forcePathStyle: true,
  // SDK 3.729+ signs a CRC header into every request; non-AWS stores reject it.
  requestChecksumCalculation: "WHEN_REQUIRED",
  responseChecksumValidation: "WHEN_REQUIRED",
  credentials: {
    accessKeyId: process.env.S3_ACCESS_KEY_ID,
    secretAccessKey: process.env.S3_SECRET_ACCESS_KEY,
  },
});

const key = `_healthcheck/${Date.now()}.txt`;
const body = "object storage reachability check";

async function step(name, fn) {
  try { await fn(); console.log(`  PASS  ${name}`); return true; }
  catch (e) { console.log(`  FAIL  ${name}: ${e.name} - ${e.message}`); return false; }
}

(async () => {
  let ok = true;
  ok = (await step("HeadBucket   (credentials valid, bucket exists, token scoped to it)",
    () => s3.send(new HeadBucketCommand({ Bucket: bucket })))) && ok;
  ok = (await step(`PutObject    ${key}`,
    () => s3.send(new PutObjectCommand({ Bucket: bucket, Key: key, Body: body, ContentType: "text/plain" })))) && ok;
  ok = (await step("GetObject    (read back and compare)", async () => {
    const r = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    const got = await r.Body.transformToString();
    if (got !== body) throw new Error(`read back ${JSON.stringify(got)}`);
  })) && ok;
  ok = (await step("DeleteObject (clean up)",
    () => s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: key })))) && ok;
  console.log(ok
    ? "\nServer-side object storage works. Now run s3-browser-verify.cjs — uploads are a different path."
    : "\nObject storage is NOT usable - see the failures above.");
  process.exit(ok ? 0 : 1);
})();
