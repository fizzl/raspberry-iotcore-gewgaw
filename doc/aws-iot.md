# AWS IoT Core integration

The device talks to AWS IoT Core over **mutual-TLS MQTT** (port 8883) using a
tiny mosquitto-based helper, `aws-iot-mqtt`. Three classes of material are
involved, with deliberately different handling:

| Material | Where it lives | Committed? | Baked into image? |
| --- | --- | --- | --- |
| Amazon Root CA (public) | `/etc/aws-iot/AmazonRootCA1.pem` | no (fetched by `setup.sh`) | **yes** |
| Connection config (endpoint, thing) | `/etc/aws-iot/aws-iot.conf` | no (only `.sample`) | yes (account-specific, gitignored) |
| Device cert + private key | `/etc/aws-iot/certs/device.{crt,key}` | **never** | **never** (provisioned over SSH) |

## Manual AWS-side setup (do this once, before building)

You need an IoT **thing**, a **certificate**, and a **policy**, plus your account's
data endpoint. The device's MQTT client id is the thing name, and its policy is
scoped to a `gewgaw/<thing>/*` topic space.

### Option A — AWS CLI

```sh
THING=gewgaw-$(openssl rand -hex 4)      # or any name you like
REGION=eu-central-1                       # pick your region

# 1. Thing
aws iot create-thing --thing-name "$THING" --region "$REGION"

# 2. Certificate + keys (saves device.crt / device.key locally)
aws iot create-keys-and-certificate --set-as-active --region "$REGION" \
  --certificate-pem-outfile device.crt \
  --private-key-outfile      device.key \
  --query certificateArn --output text          # note the printed cert ARN

# 3. Policy scoped to this thing (client id == thing, pub/sub/recv on gewgaw/<thing>/*)
cat > policy.json <<JSON
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Action": "iot:Connect",
    "Resource": "arn:aws:iot:$REGION:ACCOUNT_ID:client/$THING" },
  { "Effect": "Allow", "Action": ["iot:Publish","iot:Receive"],
    "Resource": "arn:aws:iot:$REGION:ACCOUNT_ID:topic/gewgaw/$THING/*" },
  { "Effect": "Allow", "Action": "iot:Subscribe",
    "Resource": "arn:aws:iot:$REGION:ACCOUNT_ID:topicfilter/gewgaw/$THING/*" } ]}
JSON
aws iot create-policy --policy-name "${THING}-policy" \
  --policy-document file://policy.json --region "$REGION"

# 4. Attach policy → cert, and cert → thing
aws iot attach-policy --policy-name "${THING}-policy" --target "<cert-ARN>" --region "$REGION"
aws iot attach-thing-principal --thing-name "$THING" --principal "<cert-ARN>" --region "$REGION"

# 5. Your ATS data endpoint
aws iot describe-endpoint --endpoint-type iot:Data-ATS --region "$REGION" \
  --query endpointAddress --output text
```

Replace `ACCOUNT_ID` (or use `*` while testing) and `<cert-ARN>` accordingly.

### Option B — Console

Create the thing under **IoT Core → Manage → Things → Create**, choose "auto-
generate certificate", **download `device.crt`, the private key, and activate the
cert**, then create and attach a policy with the three statements above. Get the
endpoint from **IoT Core → Settings → Device data endpoint**.

### Region matters

The device connects to whatever region your **endpoint** lives in. When you
monitor incoming messages (e.g. **MQTT test client → subscribe `gewgaw/#`**), make
sure the console is set to that same region — a region mismatch is the classic
"I see no data" red herring.

## Wiring it into the build

`setup.sh` does the non-secret parts automatically:

- `stage_amazon_root_ca` downloads the public `AmazonRootCA1.pem` into the recipe.
- `generate_aws_iot_conf` renders `aws-iot.conf` from `aws-iot.conf.sample`,
  filling endpoint + thing from `$AWS_IOT_ENDPOINT`/`$AWS_IOT_THING`, or via an
  AWS CLI lookup if you have credentials configured:

```sh
AWS_IOT_ENDPOINT="xxxxxxxxxxxx-ats.iot.eu-central-1.amazonaws.com" \
AWS_IOT_THING="$THING" ./setup.sh
```

If those fields can't be resolved, `setup.sh` warns and leaves placeholders —
edit `meta-gewgaw/recipes-iot/aws-iot/files/aws-iot.conf` before `./build.sh`.

### `aws-iot.conf`

```sh
AWS_IOT_ENDPOINT="…-ats.iot.<region>.amazonaws.com"
AWS_IOT_PORT="8883"
AWS_IOT_CLIENT_ID="<thing>"             # AWS policy pins client id == thing
AWS_IOT_TOPIC="gewgaw/<thing>/test"     # base for the helper's defaults
AWS_IOT_CAFILE="/etc/aws-iot/AmazonRootCA1.pem"
AWS_IOT_CERTFILE="/etc/aws-iot/certs/device.crt"
AWS_IOT_KEYFILE="/etc/aws-iot/certs/device.key"
```

## Provisioning the device cert (per device, after flashing)

The cert + private key are pushed to the **running** target over SSH — never
committed, never imaged:

```sh
./provision-device.sh device.crt device.key
```

This installs them into `/etc/aws-iot/certs/` (`device.crt` 0644, `device.key`
0600), clears the provisioning stamp, and runs the on-device self-test. Re-run
after every reflash.

## `aws-iot-mqtt` helper

`/usr/bin/aws-iot-mqtt` is a small `sh` wrapper over `mosquitto_pub`/`sub`. It
sources `aws-iot.conf` and builds the TLS args (CA + client cert/key, `-h
endpoint -p 8883 --tls-version tlsv1.2 -i <client-id>`; SNI is sent automatically
from `-h` on :8883). QoS 1 throughout.

```sh
aws-iot-mqtt check                  # connect + publish to gewgaw/<thing>/test/selftest
aws-iot-mqtt pub [topic] [message]  # defaults: topic=AWS_IOT_TOPIC, msg={"hello":…}
aws-iot-mqtt sub [topic]            # subscribe and stream
```

A non-zero exit means the publish/connect failed (bad certs, policy, endpoint,
network, or — on a Pi with no RTC — a clock behind the cert's `notBefore`; see
[submit.md](submit.md#clock-handling-no-rtc)). The daemons rely on this exit code:
sighting/event rows are marked `synced=1` **only** after the corresponding `pub`
exits 0.

## First-boot provisioning self-test

`aws-iot-provision.service` is a oneshot guarded by
`ConditionPathExists=!/var/lib/aws-iot-provisioned.stamp`. After
`network-online.target` it runs `aws-iot-mqtt check` and, **only on success**,
touches the stamp. So until you've provisioned the cert, it retries the self-test
every boot; once it passes, it stops. `provision-device.sh` deletes the stamp so
the next boot re-confirms.

## Topics

Derived from `AWS_IOT_TOPIC` (`gewgaw/<thing>/test`) — the daemons strip the last
segment to get the base `gewgaw/<thing>` and publish to:

| Topic | Producer | Payload |
| --- | --- | --- |
| `gewgaw/<thing>/test/selftest` | `aws-iot-mqtt check` | liveness ping |
| `gewgaw/<thing>/sightings` | `gewgaw-submit` | JSON array of closed sessions |
| `gewgaw/<thing>/status` | `gewgaw-submit` | JSON array of events (boot beacons) |

All stay within the device policy's `gewgaw/<thing>/*` scope. See
[submit.md](submit.md#upload-format) for payload shapes.
</content>
