source ../common/utils.sh
activate_python_venv
install_package wireguard libev-dev libevdev2 default-libmysqlclient-dev build-essential pkg-config ssh

useradd -m hiddify-panel -s /bin/bash >/dev/null 2>&1
usermod -aG hiddify-common hiddify-panel

echo -n "" >> ../log/system/panel.log
chown hiddify-panel ../log/system/panel.log
chsh hiddify-panel -s /bin/bash

chown -R hiddify-panel:hiddify-panel /home/hiddify-panel/ >/dev/null 2>&1
localectl set-locale LANG=C.UTF-8 >/dev/null 2>&1
su hiddify-panel -c update-locale LANG=C.UTF-8 >/dev/null 2>&1
chown -R hiddify-panel:hiddify-panel . >/dev/null 2>&1
# activate venv for hiddify-panel user
if ! grep -Fxq "source /opt/hiddify-manager/.venv313/bin/activate" "/home/hiddify-panel/.bashrc" && ! grep -Fxq "export PATH=/opt/hiddify-manager/.venv313/bin:\$PATH" "/home/hiddify-panel/.bashrc"; then
    echo "source /opt/hiddify-manager/.venv313/bin/activate" >> "/home/hiddify-panel/.bashrc"
    echo "export PATH=/opt/hiddify-manager/.venv313/bin:\$PATH" >> "/home/hiddify-panel/.bashrc"
fi


ln -sf $(pwd)/hiddify-panel.service /etc/systemd/system/hiddify-panel.service
systemctl enable hiddify-panel.service

ln -sf $(pwd)/hiddify-panel-background-tasks.service /etc/systemd/system/hiddify-panel-background-tasks.service
systemctl enable hiddify-panel-background-tasks.service

if [ -n "$HIDDIFY_PANLE_SOURCE_DIR" ]; then
    echo "NOTICE: building hiddifypanel package from source..."
    echo "NOTICE: the source dir $HIDDIFY_PANLE_SOURCE_DIR"
    uv pip install -e "$HIDDIFY_PANLE_SOURCE_DIR"
fi

rm -rf /etc/cron.d/{hiddify_usage_update,hiddify_auto_backup}
# echo "*/1 * * * * root $(pwd)/update_usage.sh" >/etc/cron.d/hiddify_usage_update
# echo "0 */6 * * * hiddify-panel $(pwd)/backup.sh" >/etc/cron.d/hiddify_auto_backup
service cron reload >/dev/null 2>&1


##### download videos

if [[ ! -e "GeoLite2-ASN.mmdb" || $(find "GeoLite2-ASN.mmdb" -mtime +1) ]]; then
    curl --connect-timeout 10 -sL -o GeoLite2-ASN.mmdb1 https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb && mv GeoLite2-ASN.mmdb1 GeoLite2-ASN.mmdb
fi
if [[ ! -e "GeoLite2-Country.mmdb" || $(find "GeoLite2-Country.mmdb" -mtime +1) ]]; then
    curl --connect-timeout 10 -sL -o GeoLite2-Country.mmdb1 https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-Country.mmdb && mv GeoLite2-Country.mmdb1 GeoLite2-Country.mmdb
fi

# bash download_yt.sh &

# TRIM/PATCH: xRay-core >=4.10.2 rejects the `allowInsecure` URI field that
# Hiddify's URI generator emits unconditionally for sub_link_only domains.
# No-op those two emit lines so generated VLESS URIs omit allowInsecure/insecure.
# All our panel domains have valid LE/ZeroSSL certs, so the flags aren't needed.
# Validated across the production fleet. Idempotent (guarded by a marker).
XRAY_PY=$(find /opt/hiddify-manager/.venv313 -path '*/hiddifypanel/hutils/proxy/xray.py' 2>/dev/null | head -1)
if [ -n "$XRAY_PY" ] && ! grep -q "PATCHED 4.10.2-compat" "$XRAY_PY"; then
    [ -f "$XRAY_PY.bak" ] || cp -p "$XRAY_PY" "$XRAY_PY.bak"
    LINE=$(grep -n "q\['allowInsecure'\] = 'true'" "$XRAY_PY" | head -1 | cut -d: -f1)
    if [ -n "$LINE" ]; then
        NEXT=$((LINE + 1))
        sed -i "${LINE}s|^.*\$|        pass  # PATCHED 4.10.2-compat: removed allowInsecure/insecure (xRay-core dropped them)|" "$XRAY_PY"
        sed -n "${NEXT}p" "$XRAY_PY" | grep -q "q\['insecure'\] = 'true'" && sed -i "${NEXT}d" "$XRAY_PY"
        /opt/hiddify-manager/.venv313/bin/python3 -m py_compile "$XRAY_PY" \
            && echo "applied xRay 4.10.2 allowInsecure patch" \
            || { echo "xray patch broke compile — reverting"; cp -p "$XRAY_PY.bak" "$XRAY_PY"; }
    fi
fi

# TRIM/PATCH: slow the Celery usage-sync from every 60s to every 300s.
# Usage accounting + GB-quota/expiry auto-disable still work (they just refresh
# every 5 min instead of every 1 min) for ~5x less per-minute CPU.
CELERY_PY=$(find /opt/hiddify-manager/.venv313 -path '*/hiddifypanel/celery.py' 2>/dev/null | head -1)
if [ -n "$CELERY_PY" ] && grep -q "add_periodic_task(60.0, usage.update_local_usage" "$CELERY_PY"; then
    sed -i 's/add_periodic_task(60.0, usage.update_local_usage/add_periodic_task(300.0, usage.update_local_usage/g' "$CELERY_PY"
    /opt/hiddify-manager/.venv313/bin/python3 -m py_compile "$CELERY_PY" \
        && echo "slowed celery usage-sync 60s->300s" || echo "celery sed broke compile (left as-is)"
fi
