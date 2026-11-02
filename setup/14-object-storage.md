# 14 — Object Storage for User Uploads (S3 / R2)

Wire an S3-compatible bucket to the application for user uploads — avatars, documents, video —
and verify it properly. Works with AWS S3, Cloudflare R2, MinIO or SeaweedFS; the differences are
noted where they matter.

This is a different job from [09-backup.md](./09-backup.md). Backups are written by a CronJob you
control, to a write-only bucket. Uploads are written by **the browser**, directly, using a URL
your server signs. That one difference is where every trap in this guide comes from.

**Time:** ~30 minutes

---

## The shape of the thing

```
browser ──(1) asks for an upload URL──▶ backend ──(2) signs it with the bucket credentials
   │                                                        │
   └──(3) PUTs the bytes STRAIGHT to the bucket ◀────────────┘
```

The credentials never leave your backend. The bytes never pass through it. That is the point: a
2 GB video upload does not occupy a pod for ten minutes.

It also means **your backend being healthy tells you nothing about whether uploads work.** Step 3
involves the browser, the bucket's CORS policy, and a signature your server produced but cannot
test by using it. Steps 5 and 6 below check each half separately, on purpose.

---

## Step 1: Create the bucket and a scoped credential

Create the bucket (`{{S3_UPLOADS_BUCKET}}`), then create credentials **scoped to that bucket
only**:

- **AWS S3:** an IAM user with a policy limited to `arn:aws:s3:::{{S3_UPLOADS_BUCKET}}/*`
- **Cloudflare R2:** R2 → Overview → Manage API Tokens → **Object Read & Write**, and
  **Apply to specific buckets only**
- **MinIO:** a service account with a bucket-scoped policy

Never give the application an account-wide credential. The upload path is the part of your system
most exposed to the public, and a token that can only touch one bucket turns a signing bug into a
bad day rather than an incident.

> **Do not use IP address filtering on this credential**, however tempting it looks on a
> single-server deployment. The URLs you sign are used **from your users' browsers**, from
> addresses you cannot predict. The restriction applies to the credential, not to a class of
> request, so an allowlist containing your server blocks your users.
>
> There is a second trap if you try it anyway: a dual-stack host and a single-stack CNI do not
> egress from the same address.
>
> ```
> host egress : 2a02:…::1     ← the host prefers IPv6
> pod egress  : 203.0.113.10  ← pods NAT out over IPv4
> ```
>
> An allowlist with only the IPv4 address covers your pods and silently blocks anything you run
> from the host itself: a backup, a cron job, an `rclone` sync. Bucket scoping is the control
> that fits here.

## Step 2: Get the endpoint right

This is the single most common failure, and it does not look like what it is.

| Store | `S3_ENDPOINT` |
|---|---|
| AWS S3 | leave unset — the SDK derives it from the region |
| Cloudflare R2 | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` |
| MinIO / SeaweedFS | `http://minio.shared:9000` |

Note what is **not** in the R2 row: the bucket. The endpoint is the *account* endpoint, and the
bucket goes in the path, because the client is configured with `forcePathStyle: true`:

```js
new S3Client({
  region: process.env.S3_REGION || "auto",   // R2 ignores region; "auto" is conventional
  endpoint: process.env.S3_ENDPOINT,
  forcePathStyle: true,
  credentials: { accessKeyId: ..., secretAccessKey: ... },
})
```

The dashboard will cheerfully show you a bucket-specific URL. Using it produces
`SignatureDoesNotMatch`, which reads exactly like a wrong secret key — so people rotate the key,
get the same error, and conclude the store is broken.

**Also set the checksum options**, if your SDK is `@aws-sdk/client-s3` 3.729 or newer:

```js
  requestChecksumCalculation: "WHEN_REQUIRED",
  responseChecksumValidation: "WHEN_REQUIRED",
```

The default signs a CRC header into every request. Non-AWS stores reject it, and — worse for
this guide — a presigned part URL ends up carrying a checksum header **no browser can produce**,
so the upload fails signature validation for a reason that has nothing to do with your signature.

## Step 3: Store the credentials in Infisical

Unlike the backup credentials in 09, these **do** belong in the vault: the application needs them
at runtime, and the application is already dead without the vault, so there is no new dependency.

Under the application's path, add:

| Key | Example |
|---|---|
| `S3_BUCKET` | `{{S3_UPLOADS_BUCKET}}` |
| `S3_ENDPOINT` | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` |
| `S3_REGION` | `auto` (R2) or `{{AWS_REGION}}` (S3) |
| `S3_ACCESS_KEY_ID` | from Step 1 |
| `S3_SECRET_ACCESS_KEY` | from Step 1 |

Write them in from a hidden prompt, never as a shell argument:

```bash
read -rsp 'secret access key: ' V && printf '%s' "$V" | <your-infisical-setter>; unset V
```

A value passed in `argv` is visible in `ps`, in your shell history, and in any transcript of the
session. See [11-security-hardening.md](./11-security-hardening.md).

## Step 4: Set the bucket's CORS policy

Without this, every browser upload fails while your server logs stay perfectly clean.

```json
[
  {
    "AllowedOrigins": ["https://{{DOMAIN}}"],
    "AllowedMethods": ["GET", "PUT", "HEAD"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3600
  }
]
```

`"ExposeHeaders": ["ETag"]` is **not optional** for multipart uploads, and it is the line people
leave out. Completing a multipart upload requires sending back each part's `ETag`. The browser
receives that header on every successful PUT — and cannot read it from JavaScript unless it is
explicitly exposed. So the parts upload, every PUT returns 200, and the final
`CompleteMultipartUpload` fails with an empty part list. Nothing in the server logs explains it.

List every origin that uploads: production, staging, and `http://localhost:3000` if your
developers upload from their machines.

## Step 5: Verify the server half

```bash
POD=$(kubectl -n {{NAMESPACE}} get pod -l app={{PROJECT_NAME}}-backend -o jsonpath='{.items[0].metadata.name}')
kubectl -n {{NAMESPACE}} cp templates/scripts/s3-verify.cjs "$POD":/tmp/s3-verify.cjs
kubectl -n {{NAMESPACE}} exec "$POD" -- sh -c 'NODE_PATH=/app/node_modules node /tmp/s3-verify.cjs'
```

`NODE_PATH` is not decoration. A container with a read-only root filesystem — which yours should
have — forces you to write the script to `/tmp`, which is outside the app tree, so Node's
resolver never walks up into `node_modules` and you get `ERR_MODULE_NOT_FOUND` for a package
that is plainly installed. `NODE_PATH` fixes that for CommonJS and is **ignored for ESM**, which
is why these scripts are `.cjs`.

`HeadBucket` → `PutObject` → `GetObject` (bytes compared) → `DeleteObject`, under a
`_healthcheck/` prefix, using the pod's real environment. Expected:

```
  PASS  HeadBucket   (credentials valid, bucket exists, token scoped to it)
  PASS  PutObject    _healthcheck/1699999999999.txt
  PASS  GetObject    (read back and compare)
  PASS  DeleteObject (clean up)
```

Run it from inside a pod, not from your laptop. Your laptop has different DNS, a different egress
address and possibly a different endpoint — it can pass while the cluster cannot reach the store
at all.

## Step 6: Verify the browser half — the one that actually breaks

**Step 5 passing does not mean uploads work.** It exercises none of CORS, none of presigning, and
none of the ETag path. Run the second script:

```bash
kubectl -n {{NAMESPACE}} cp templates/scripts/s3-browser-verify.cjs "$POD":/tmp/s3-browser-verify.cjs
kubectl -n {{NAMESPACE}} exec "$POD" -- sh -c \
  'NODE_PATH=/app/node_modules node /tmp/s3-browser-verify.cjs https://{{DOMAIN}}'
```

It presigns an `UploadPart` URL the way your backend does, then PUTs to it with **no credentials
at all** and an `Origin` header — which is what a browser is:

```
  PASS  CORS preflight  allow-origin: https://{{DOMAIN}}  methods: GET, PUT, HEAD
  PASS  CORS rejects an unlisted origin
  PASS  CreateMultipartUpload
  PASS  presigned UploadPart URL
  PASS  browser PUT    HTTP 200, 1024 bytes, no credentials sent
  PASS  ETag returned  "7265f4d211b56873a381d321f586e4a9"
  PASS  ETag exposed to the browser  (expose-headers: ETag)
  PASS  CompleteMultipartUpload
```

The second line matters as much as the first: it confirms your policy is scoped rather than open
to any origin.

---

## Troubleshooting

### `SignatureDoesNotMatch`

Almost never the secret key. In order of likelihood:

1. The bucket is in the endpoint hostname instead of the path — see Step 2.
2. `forcePathStyle` is not set.
3. The SDK is adding checksum headers — set both `WHEN_REQUIRED` options.
4. Clock skew on the node. `timedatectl status` should show NTP synchronised.

### The browser shows a CORS error, but CORS is configured

It may not be a CORS failure at all. S3-compatible stores commonly omit CORS headers from **4xx
responses**, so a 403 from a bad signature or an expired URL reaches the browser with no
`Access-Control-Allow-Origin` header and is reported as a CORS error. Check the actual status
code in the network tab: a 403 is a signing or permissions problem wearing a CORS costume.

### Uploads work for small files and fail for large ones

Large files go through the multipart path and small ones do not. That is the `ExposeHeaders:
["ETag"]` line in Step 4.

### Everything passes but uploads still fail in the app

Check `S3_PUBLIC_ENDPOINT` if your setup has one. When browsers reach the store on a different
hostname than the cluster does — an internal service name versus a public URL — the signature is
produced for the wrong host. Leave it unset when both reach the same endpoint.

---

## What you have now

- An upload bucket with a credential scoped to it alone
- Credentials in Infisical, never in `argv` or git
- A CORS policy that permits your origins and refuses others, with `ETag` exposed so multipart
  uploads can complete
- Two verification scripts that fail for **different reasons**, so a failure tells you which half
  is broken

**Next:** [11-security-hardening.md](./11-security-hardening.md) — lock down what you just opened.
