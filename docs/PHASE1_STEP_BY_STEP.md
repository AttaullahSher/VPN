# Creating the instance — two routes

## Route A (recommended): Cloud Shell

Ten taps instead of a forty-field form, and it solves "Out of host capacity"
for free because it retries automatically.

### A1. Create the network (once)

1. **☰** → **Networking** → **Virtual Cloud Networks**
2. **Start VCN Wizard** → select **Create VCN with Internet Connectivity** → **Start VCN Wizard**
3. **VCN name:** `vpn-vcn`. Leave every CIDR at its default.
4. **Next** → **Create** → wait for green ticks → **Close**

### A2. Launch the instance

1. Tap the **`>_`** icon in the console's top bar (Cloud Shell). Wait for the prompt.
2. Paste the block from `oracle/cloudshell-launch-retry.sh` (or the one your
   assistant gives you) and press return.
3. Leave the tab open. It prints an attempt line every 60 seconds and stops the
   moment it succeeds, showing the public IP.

Want it to land faster? `OCPUS=1 MEMGB=6 bash launch.sh` — a 1 OCPU / 6 GB
instance is allocated far more readily and can be resized up later from the
console with a stop/start, keeping the same IP and disk.

---

## Route B: the console form, field by field

The Create Instance page is one long scrolling form. Work top to bottom and
leave anything not mentioned here at its default.

| # | Section | What to do |
|---|---|---|
| 1 | **Name** | Replace the generated name with `wg-vpn`. |
| 2 | **Create in compartment** | Leave as-is (the root compartment). |
| 3 | **Placement** | Abu Dhabi has one availability domain, so there is nothing to choose. Do not enable capacity reservations. |
| 4 | **Security** | Leave Shielded instance and Confidential computing **off**. Neither is supported on Always Free Ampere. |
| 5 | **Image and shape** | Tap **Edit** to expand it. Then follow 5a–5b. |
| 5a | → **Change image** | A panel slides in. Under image source keep **Platform images**. Tap **Canonical Ubuntu**. In the OS-version dropdown on that row pick **24.04**. Confirm the row shows an **Always Free-eligible** chip. Tap **Select image**. |
| 5b | → **Change shape** | Instance type: **Virtual machine**. Shape series: **Ampere**. Tap **VM.Standard.A1.Flex**. Two sliders appear — set **OCPUs = 2**; memory jumps to **12 GB** on its own. Check for the **Always Free-eligible** chip. Tap **Select shape**. |
| 6 | **Networking** | Primary network: **Create new virtual cloud network** (or select `vpn-vcn` if you already made one). Subnet: **Create new subnet**, type **Public**. **Assign a public IPv4 address: Yes** ← easy to miss, and without it nothing works. |
| 7 | **Add SSH keys** | Select **Paste public keys** and paste the key. Not "Generate a key pair for me" — you would then have to move a downloaded file off your phone. |
| 8 | **Boot volume** | Leave everything unticked. The 46.6 GB default is inside the free 200 GB allowance. |
| 9 | **Show advanced options** | Tap it, go to the **Management** tab, find **Initialization script**, choose **Paste cloud-init script**, paste the YAML. |
| 10 | | Tap **Create**. Provisioning → Running takes about a minute. |

The public IP appears on the instance detail page under **Instance access** /
**Primary VNIC**, labelled **Public IP address**.

### If you see "Out of host capacity"

Expected, and not something you did wrong. In order of how well each actually
works:

1. **Retry on a loop** — use Route A. Capacity frees in seconds-long bursts as
   other people delete instances; hand-tapping Create almost never catches one.
2. **Ask for less** — 1 OCPU / 6 GB succeeds far more often. Resize later.
3. **Upgrade to Pay As You Go** — the reliable fix. Free resources stay free,
   PAYG is not queued behind free-tier for Ampere, and it removes idle
   reclamation too. Set a budget alert at 1 USD on day one.
4. **`VM.Standard.E2.1.Micro`** — x86, 1 GB, always available. WireGuard runs
   fine on it for four people, but Always Free micro is throttled to roughly
   50 Mbit/s against ~1 Gbit/s per OCPU on A1. A stopgap, not a destination.
