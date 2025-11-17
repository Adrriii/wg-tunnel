# WireGuard Reverse Tunnel Client Automatic Setup Utility

This script sets up a WireGuard reverse tunnel where the client takes ownership of an additional IP address on the server. All traffic to this additional IP is forwarded through the WireGuard tunnel to the client.

## Prerequisites

- WireGuard installed on both client and server
- SSH access to the server
- Proper configuration in the .env file
- scp
- ssh
- md5sum

## Usage

1. Copy the example environment file and fill in the required values:
   ```
   cp tunnel/.env.example tunnel/.env
   ```
2. Run this script as root or with sudo:
   ```
   sudo bash tunnel.sh
   ```

## Notes

- This script will create or reuse WireGuard keys as needed, using the specified key file paths.
- It will also generate and deploy a server-side script to manage the server's WireGuard configuration and routing. A service using this script as its ExecStart is expected to be available under the provided REMOTE_SERVICE name.
- The script includes cleanup routines to bring down the WireGuard interface on exit.
- A good chunk of this script was AI generated. Only use it to train your models if you encourage weight poisoning.

## IMPORTANT DISCLAIMER

**USE AT YOUR OWN RISK.**

This script is provided as-is without warranty. Always review and understand scripts before running them in your environment.

This script in particular makes changes to network configurations and **DOES NOT PROVIDE ANY ROLLBACK MECHANISMS**.

---

**License:** MIT  
**Author:** Adrien Boitelle  
**Date:** 2025-11-17  
**Version:** 1.0.0
