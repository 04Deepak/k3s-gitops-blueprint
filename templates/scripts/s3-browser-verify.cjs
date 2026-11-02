// Verify the BROWSER half of object storage, which is where uploads actually break.
//
//   kubectl -n NS exec POD -- sh -c 'NODE_PATH=/app/node_modules node /tmp/s3-browser-verify.cjs https://app.example.com'
//
// The server presigns an UploadPart URL and the browser PUTs the bytes straight at the bucket.
// Credentials never make that trip, so none of this is covered by s3-verify.cjs: it tests CORS,
// the signature as a browser presents it, and whether the ETag is READABLE — which is what
// CompleteMultipartUpload needs and what a missing ExposeHeaders rule silently withholds.
const {
  S3Client, CreateMultipartUploadCommand, UploadPartCommand,
  CompleteMultipartUploadCommand, AbortMultipartUploadCommand, DeleteObjectCommand,
} = require("@aws-sdk/client-s3");
const { getSignedUrl } = require("@aws-sdk/s3-request-presigner");

const ORIGIN = process.argv[2];
if (!ORIGIN) { console.log("usage: node s3-browser-verify.cjs https://your-app-origin"); process.exit(2); }
const bucket = process.env.S3_BUCKET;
const endpoint = process.env.S3_ENDPOINT;
if (!bucket || !endpoint) { console.log("MISSING: S3_BUCKET and/or S3_ENDPOINT"); process.exit(2); }

const s3 = new S3Client({
  region: process.env.S3_REGION || "auto",
  endpoint,
  forcePathStyle: true,
  // Without WHEN_REQUIRED the presigned URL carries a checksum header no browser can produce,
  // and the PUT fails signature validation for a reason unrelated to your signature.
  requestChecksumCalculation: "WHEN_REQUIRED",
  responseChecksumValidation: "WHEN_REQUIRED",
  credentials: {
    accessKeyId: process.env.S3_ACCESS_KEY_ID,
    secretAccessKey: process.env.S3_SECRET_ACCESS_KEY,
  },
});

const key = `_healthcheck/browser-${Date.now()}.bin`;
const body = Buffer.from("x".repeat(1024));
let pass = true;
const ok   = (m) => console.log(`  PASS  ${m}`);
const fail = (m) => { console.log(`  FAIL  ${m}`); pass = false; };

(async () => {
  let uploadId;
  try {
    const pre = await fetch(`${endpoint}/${bucket}/${key}`, {
      method: "OPTIONS",
      headers: {
        Origin: ORIGIN,
        "Access-Control-Request-Method": "PUT",
        "Access-Control-Request-Headers": "content-type",
      },
    });
    const allow = pre.headers.get("access-control-allow-origin");
    allow === ORIGIN || allow === "*"
      ? ok(`CORS preflight  allow-origin: ${allow}  methods: ${pre.headers.get("access-control-allow-methods")}`)
      : fail(`CORS preflight  HTTP ${pre.status}, allow-origin: ${allow ?? "(absent)"} - browser uploads will be blocked`);

    const bad = await fetch(`${endpoint}/${bucket}/${key}`, {
      method: "OPTIONS",
      headers: { Origin: "https://unlisted.example", "Access-Control-Request-Method": "PUT" },
    });
    bad.headers.get("access-control-allow-origin")
      ? fail("CORS is open to any origin (https://unlisted.example was allowed)")
      : ok("CORS rejects an unlisted origin");

    uploadId = (await s3.send(new CreateMultipartUploadCommand({
      Bucket: bucket, Key: key, ContentType: "application/octet-stream",
    }))).UploadId;
    ok(`CreateMultipartUpload  uploadId ${uploadId.slice(0, 12)}...`);

    const url = await getSignedUrl(s3, new UploadPartCommand({
      Bucket: bucket, Key: key, UploadId: uploadId, PartNumber: 1, ContentLength: body.length,
    }), { expiresIn: 300 });
    ok("presigned UploadPart URL");

    const put = await fetch(url, { method: "PUT", body, headers: { Origin: ORIGIN } });
    if (!put.ok) { fail(`browser PUT  HTTP ${put.status} ${put.statusText}`); throw new Error("upload failed"); }
    ok(`browser PUT    HTTP ${put.status}, ${body.length} bytes, no credentials sent`);

    const etag = put.headers.get("etag");
    const expose = put.headers.get("access-control-expose-headers") || "";
    etag ? ok(`ETag returned  ${etag}`) : fail("no ETag on the PUT response");
    /etag/i.test(expose)
      ? ok(`ETag exposed to the browser  (expose-headers: ${expose})`)
      : fail(`ETag NOT exposed (expose-headers: ${expose || "absent"}) - JS cannot read it, so CompleteMultipartUpload never gets the part`);

    await s3.send(new CompleteMultipartUploadCommand({
      Bucket: bucket, Key: key, UploadId: uploadId,
      MultipartUpload: { Parts: [{ PartNumber: 1, ETag: etag }] },
    }));
    uploadId = undefined;
    ok("CompleteMultipartUpload");

    await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
    ok("cleaned up");
  } catch (e) {
    fail(`${e.name} - ${e.message}`);
    if (uploadId) {
      try { await s3.send(new AbortMultipartUploadCommand({ Bucket: bucket, Key: key, UploadId: uploadId })); }
      catch { /* an abandoned multipart upload costs nothing and the store expires it */ }
    }
  }
  console.log(pass
    ? "\nThe browser upload path works end to end."
    : "\nThe browser upload path is BROKEN - see the failures above.");
  process.exit(pass ? 0 : 1);
})();
