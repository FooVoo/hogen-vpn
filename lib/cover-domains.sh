#!/usr/bin/env bash
# lib/cover-domains.sh — shared cover-domain pool for VLESS/REALITY and MTProxy FakeTLS.
#
# Source this file; it populates the COVER_DOMAINS bash array.
# All entries serve TLS 1.3 on port 443 and are unsuspicious from Russian IPs.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/cover-domains.sh"
#   # COVER_DOMAINS array is now available.

COVER_DOMAINS=(
  # International — accessible from Russia
  "www.microsoft.com"
  "www.cloudflare.com"
  "github.com"
  "www.bing.com"
  "www.apple.com"
  "www.google.com"
  "www.samsung.com"
  "www.nvidia.com"
  "www.intel.com"
  "www.oracle.com"
  "www.ibm.com"
  "learn.microsoft.com"
  "www.lenovo.com"
  "www.amd.com"
  "www.hp.com"
  "www.cisco.com"
  "www.jetbrains.com"
  "www.aliexpress.com"
  "www.yahoo.com"
  "www.docker.com"
  # Russian domestic — high-traffic, unsuspicious from RU IPs
  "www.yandex.ru"
  "mail.ru"
  "www.vk.com"
  "www.ozon.ru"
  "www.wildberries.ru"
  "www.sberbank.ru"
  "www.tinkoff.ru"
  "www.gosuslugi.ru"
  "www.avito.ru"
  "habr.com"
  "www.kaspersky.ru"
  "www.dns-shop.ru"
  "www.mos.ru"
  "www.rt.com"
  "www.gazprom.ru"
)
