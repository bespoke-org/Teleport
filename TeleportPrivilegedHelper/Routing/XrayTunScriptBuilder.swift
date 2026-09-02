import Foundation

struct XrayTunScriptBuilder: Sendable {
    let installedXrayPath: String

    func makeStartScript(helperStateDirectoryPath: String, configPath: String, protectedHost: String, tunnelInterfaceName: String, outboundInterface: String) -> String {
        let q = shellQuote
        let pidFile = helperStateDirectoryPath + "/xray-tun.pid"
        let logFile = helperStateDirectoryPath + "/xray-tun.log"
        let protectedHostFile = helperStateDirectoryPath + "/xray-tun-protected-host"
        let protectedDNSFile = helperStateDirectoryPath + "/xray-tun-protected-dns"
        let controlLogFile = helperStateDirectoryPath + "/xray-tun-control.log"

        // This generated script does not return until Xray has created a TUN and
        // both IPv4 half-default routes have passed post-install checks.
        // TODO(gpt-5.6-sol): Convert route changes into a journaled transaction with
        // one EXIT/signal cleanup trap. The script has many explicit error branches,
        // but an unexpected `set -e` failure can bypass them and leave partial root
        // state. Record exact route tuples so cleanup removes only this session's
        // mutations rather than every route that shares a destination prefix.
        return """
        set -eu
        HELPER_STATE_DIR=\(q(helperStateDirectoryPath))
        PID_FILE=\(q(pidFile))
        LOG_FILE=\(q(logFile))
        PROTECTED_HOST_FILE=\(q(protectedHostFile))
        PROTECTED_DNS_FILE=\(q(protectedDNSFile))
        CONTROL_LOG_FILE=\(q(controlLogFile))
        XRAY=\(q(installedXrayPath))
        XRAY_ASSET_DIR=\(q(PrivilegedHelperConstants.installedAssetDirectoryPath))
        CONFIG=\(q(configPath))
        PROTECTED_HOST=\(q(protectedHost))
        TUN_INTERFACE_NAME=\(q(tunnelInterfaceName))
        OUTBOUND_INTERFACE=\(q(outboundInterface))

        \(deleteHostRouteFunction())
        \(dnsRouteFunctions())
        \(directRouteFunctions())

        for helper_file in "$PID_FILE" "$LOG_FILE" "$PROTECTED_HOST_FILE" "$PROTECTED_DNS_FILE" "$CONTROL_LOG_FILE"; do
            [ ! -L "$helper_file" ] || rm -f "$helper_file"
        done

        touch "$CONTROL_LOG_FILE"
        chmod 600 "$CONTROL_LOG_FILE"
        printf '%s helper start requested for %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PROTECTED_HOST" >> "$CONTROL_LOG_FILE"

        if [ -f "$PROTECTED_HOST_FILE" ]; then
            old_protected_host=$(cat "$PROTECTED_HOST_FILE" 2>/dev/null || true)
            if [ -n "$old_protected_host" ]; then
                delete_host_route "$old_protected_host"
            fi
        fi
        cleanup_dns_routes
        cleanup_direct_routes

        route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
        route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true

        rm -f "$PID_FILE"
        : > "$LOG_FILE"
        chmod 600 "$LOG_FILE"
        printf '%s\n' "$PROTECTED_HOST" > "$PROTECTED_HOST_FILE"
        chmod 600 "$PROTECTED_HOST_FILE"

        delete_host_route "$PROTECTED_HOST"
        gateway=$(route -n get "$PROTECTED_HOST" 2>/dev/null | awk '/gateway:/{print $2; exit}')
        \(protectHostRouteCommands())
        protect_direct_routes "$gateway"
        protect_dns_routes

        cd "$HELPER_STATE_DIR"
        (
            trap '' HUP
            XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR"
            export XRAY_LOCATION_ASSET
            exec "$XRAY" run -c "$CONFIG"
        ) </dev/null >> "$LOG_FILE" 2>&1 &
        pid=$!
        printf '%s\n' "$pid" > "$PID_FILE"
        chmod 600 "$PID_FILE"
        printf '%s helper launched pid %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" >> "$CONTROL_LOG_FILE"

        tun_interface=""
        readiness_attempt=0
        while [ -z "$tun_interface" ] && [ "$readiness_attempt" -lt 20 ]; do
            sleep 0.5
            readiness_attempt=$((readiness_attempt + 1))

            \(protectHostRouteCommands())
            protect_dns_routes

            if ! kill -0 "$pid" >/dev/null 2>&1; then
                printf '%s pid %s exited during readiness wait\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" >> "$CONTROL_LOG_FILE"
                delete_host_route "$PROTECTED_HOST"
                cleanup_dns_routes
                cleanup_direct_routes
                rm -f "$PID_FILE"
                cat "$LOG_FILE" >&2 || true
                exit 1
            fi

            if ifconfig "$TUN_INTERFACE_NAME" >/dev/null 2>&1; then
                tun_interface="$TUN_INTERFACE_NAME"
            fi
            if [ -z "$tun_interface" ]; then
                tun_interface=$(ifconfig | awk '
                    /^utun[0-9]+:/ { iface=$1; sub(":", "", iface); next }
                    /inet 169\\.254\\./ { print iface; exit }
                    /inet 172\\.18\\.0\\.1/ { print iface; exit }
                    /inet 198\\.18\\./ { print iface; exit }
                ')
            fi
        done

        if [ -z "$tun_interface" ]; then
            reason="Teleport VPN started Xray, but macOS did not create a TUN interface."
            printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" >> "$CONTROL_LOG_FILE"
            ifconfig >> "$CONTROL_LOG_FILE" 2>&1 || true
            printf '%s\n' "$reason" >&2
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
            delete_host_route "$PROTECTED_HOST"
            cleanup_dns_routes
            cleanup_direct_routes
            rm -f "$PID_FILE"
            exit 1
        fi

        route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
        route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
        if ! route add -net 0.0.0.0/1 -interface "$tun_interface" >> "$CONTROL_LOG_FILE" 2>&1; then
            reason="Teleport VPN could not install the lower IPv4 default route through Teleport's TUN."
            printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" >> "$CONTROL_LOG_FILE"
            printf '%s\n' "$reason" >&2
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
            route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
            route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
            delete_host_route "$PROTECTED_HOST"
            cleanup_dns_routes
            cleanup_direct_routes
            rm -f "$PID_FILE"
            exit 1
        fi
        if ! route add -net 128.0.0.0/1 -interface "$tun_interface" >> "$CONTROL_LOG_FILE" 2>&1; then
            reason="Teleport VPN could not install the upper IPv4 default route through Teleport's TUN."
            printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" >> "$CONTROL_LOG_FILE"
            printf '%s\n' "$reason" >&2
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
            route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
            route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
            delete_host_route "$PROTECTED_HOST"
            cleanup_dns_routes
            cleanup_direct_routes
            rm -f "$PID_FILE"
            exit 1
        fi

        \(protectHostRouteCommands())
        protect_direct_routes "$gateway"
        protect_dns_routes

        public_interface_low=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
        public_interface_high=$(route -n get 129.0.0.1 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
        protected_interface=$(route -n get "$PROTECTED_HOST" 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
        printf '%s pid %s running, tun %s, public low route %s, public high route %s, protected route %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" "$tun_interface" "${public_interface_low:-unknown}" "${public_interface_high:-unknown}" "${protected_interface:-unknown}" >> "$CONTROL_LOG_FILE"

        case "$public_interface_low" in
            utun*) ;;
            *)
                reason="Teleport VPN started Xray, but macOS did not route lower-half public traffic through Teleport's TUN. Disconnect other VPN apps and try again."
                printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" >> "$CONTROL_LOG_FILE"
                netstat -rn -f inet >> "$CONTROL_LOG_FILE" 2>&1 || true
                printf '%s\n' "$reason" >&2
                kill "$pid" 2>/dev/null || true
                sleep 0.5
                kill -9 "$pid" 2>/dev/null || true
                route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
                route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
                delete_host_route "$PROTECTED_HOST"
                cleanup_dns_routes
                cleanup_direct_routes
                rm -f "$PID_FILE"
                exit 1
                ;;
        esac

        case "$public_interface_high" in
            utun*) ;;
            *)
                reason="Teleport VPN started Xray, but macOS did not route upper-half public traffic through Teleport's TUN. Disconnect other VPN apps and try again."
                printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" >> "$CONTROL_LOG_FILE"
                netstat -rn -f inet >> "$CONTROL_LOG_FILE" 2>&1 || true
                printf '%s\n' "$reason" >&2
                kill "$pid" 2>/dev/null || true
                sleep 0.5
                kill -9 "$pid" 2>/dev/null || true
                route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
                route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
                delete_host_route "$PROTECTED_HOST"
                cleanup_dns_routes
                cleanup_direct_routes
                rm -f "$PID_FILE"
                exit 1
                ;;
        esac

        case "$protected_interface" in
            utun*)
                reason="Teleport VPN could not keep the proxy server route outside the tunnel. Disconnect other VPN apps and try again, or use System Proxy mode."
                printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" >> "$CONTROL_LOG_FILE"
                printf '%s\n' "$reason" >&2
                kill "$pid" 2>/dev/null || true
                sleep 0.5
                kill -9 "$pid" 2>/dev/null || true
                route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
                route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
                delete_host_route "$PROTECTED_HOST"
                cleanup_dns_routes
                cleanup_direct_routes
                rm -f "$PID_FILE"
                exit 1
                ;;
        esac

        printf '%s pid %s ready\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" >> "$CONTROL_LOG_FILE"
        exit 0
        """
    }

    func makeStopScript(helperStateDirectoryPath: String, protectedHost: String?, outboundInterface: String?) -> String {
        let q = shellQuote
        let pidFile = helperStateDirectoryPath + "/xray-tun.pid"
        let protectedHostFile = helperStateDirectoryPath + "/xray-tun-protected-host"
        let protectedDNSFile = helperStateDirectoryPath + "/xray-tun-protected-dns"
        let configFile = helperStateDirectoryPath + "/xray-tun-config.json"
        let controlLogFile = helperStateDirectoryPath + "/xray-tun-control.log"

        var commands: [String] = []
        commands.append("OUTBOUND_INTERFACE=\(q(outboundInterface ?? ""))")
        commands.append("PROTECTED_DNS_FILE=\(q(protectedDNSFile))")
        commands.append("CONTROL_LOG_FILE=\(q(controlLogFile))")
        commands.append(deleteHostRouteFunction())
        commands.append(dnsRouteFunctions())
        commands.append(directRouteFunctions())
        commands.append("for helper_file in \(q(pidFile)) \(q(protectedHostFile)) \(q(protectedDNSFile)) \(q(controlLogFile)); do [ ! -L \"$helper_file\" ] || rm -f \"$helper_file\"; done")
        commands.append("touch \(q(controlLogFile)); chmod 600 \(q(controlLogFile))")
        commands.append("printf '%s helper stop requested\\n' \"$(date '+%Y-%m-%d %H:%M:%S')\" >> \(q(controlLogFile))")
        if let protectedHost, !protectedHost.isEmpty {
            commands.append("delete_host_route \(q(protectedHost))")
        } else {
            commands.append("if [ -f \(q(protectedHostFile)) ]; then protected_host=$(cat \(q(protectedHostFile)) 2>/dev/null || true); if [ -n \"$protected_host\" ]; then delete_host_route \"$protected_host\"; fi; fi")
        }
        commands.append("cleanup_dns_routes")
        commands.append("cleanup_direct_routes")
        // TODO(gpt-5.6-sol): These destination-only deletes are not tied to a
        // Teleport session, and `|| true` hides cleanup failures from the client.
        // Delete only journaled routes and report any route that could not be removed.
        commands.append("route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true")
        commands.append("route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true")
        commands.append("rm -f \(q(pidFile))")
        commands.append("rm -f \(q(protectedHostFile))")
        commands.append("rm -f \(q(protectedDNSFile))")
        commands.append("rm -f \(q(configFile))")
        return commands.joined(separator: "; ")
    }

    private func deleteHostRouteFunction() -> String {
        """
        delete_host_route() {
            host="$1"
            current_interface=$(route -n get "$host" 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
            for scoped_interface in "${OUTBOUND_INTERFACE:-}" "$current_interface" en0 en1 en2 bridge100; do
                [ -n "$scoped_interface" ] || continue
                i=0
                while route delete -host -ifscope "$scoped_interface" "$host" >/dev/null 2>&1; do
                    i=$((i + 1))
                    [ "$i" -ge 10 ] && break
                done
            done
            i=0
            while route delete -host "$host" >/dev/null 2>&1; do
                i=$((i + 1))
                [ "$i" -ge 10 ] && break
            done
        }
        """
    }

    private func dnsRouteFunctions() -> String {
        // TODO(gpt-5.6-sol): Public DNS host routes deliberately bypass the TUN for
        // the whole machine, not only for Xray. That can leak DNS queries during a
        // session advertised as whole-device VPN. Route DNS through an explicit Xray
        // resolver, or disclose and test this bypass as part of the product contract.
        """
        is_public_ipv4() {
            ip="$1"
            case "$ip" in
                ""|*[!0-9.]*|*.*.*.*.*) return 1 ;;
            esac
            o1=${ip%%.*}
            rest=${ip#*.}
            o2=${rest%%.*}
            case "$o1" in
                0|10|127) return 1 ;;
                169) [ "$o2" = "254" ] && return 1 ;;
                172) [ "$o2" -ge 16 ] 2>/dev/null && [ "$o2" -le 31 ] 2>/dev/null && return 1 ;;
                192) [ "$o2" = "168" ] && return 1 ;;
            esac
            [ "$o1" -ge 224 ] 2>/dev/null && return 1
            return 0
        }

        cleanup_dns_routes() {
            if [ -f "$PROTECTED_DNS_FILE" ]; then
                while IFS= read -r dns_server; do
                    [ -n "$dns_server" ] || continue
                    delete_host_route "$dns_server"
                done < "$PROTECTED_DNS_FILE"
            fi
            rm -f "$PROTECTED_DNS_FILE"
        }

        protect_dns_routes() {
            : > "$PROTECTED_DNS_FILE"
            chmod 600 "$PROTECTED_DNS_FILE"
            scutil --dns 2>/dev/null | awk '/nameserver\\[[0-9]+\\]/{print $3}' | sort -u | while IFS= read -r dns_server; do
                is_public_ipv4 "$dns_server" || continue
                delete_host_route "$dns_server"
                dns_gateway=$(route -n get "$dns_server" 2>/dev/null | awk '/gateway:/{print $2; exit}' || true)
                dns_interface=$(route -n get "$dns_server" 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
                case "$dns_interface" in
                    utun*) dns_gateway="${gateway:-$dns_gateway}" ;;
                esac
                if [ -z "$dns_gateway" ]; then
                    dns_gateway="${gateway:-}"
                fi
                if [ -n "$dns_gateway" ]; then
                    route add -host "$dns_server" "$dns_gateway" >> "$CONTROL_LOG_FILE" 2>&1 || route change -host "$dns_server" "$dns_gateway" >> "$CONTROL_LOG_FILE" 2>&1 || true
                    printf '%s\n' "$dns_server" >> "$PROTECTED_DNS_FILE"
                fi
            done
        }
        """
    }

    private func directRouteFunctions() -> String {
        """
        cleanup_direct_routes() {
            [ -n "${OUTBOUND_INTERFACE:-}" ] || return 0
            route delete -net 0.0.0.0/1 -ifscope "$OUTBOUND_INTERFACE" >/dev/null 2>&1 || true
            route delete -net 128.0.0.0/1 -ifscope "$OUTBOUND_INTERFACE" >/dev/null 2>&1 || true
        }

        protect_direct_routes() {
            direct_gateway="$1"
            [ -n "${OUTBOUND_INTERFACE:-}" ] || return 0
            [ "$OUTBOUND_INTERFACE" != "auto" ] || return 0
            [ -n "$direct_gateway" ] || return 0

            cleanup_direct_routes
            route add -net 0.0.0.0/1 "$direct_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || \
                route change -net 0.0.0.0/1 "$direct_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || true
            route add -net 128.0.0.0/1 "$direct_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || \
                route change -net 128.0.0.0/1 "$direct_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || true
        }
        """
    }

    private func protectHostRouteCommands() -> String {
        """
        if [ -n "$gateway" ]; then
            delete_host_route "$PROTECTED_HOST"
            route add -host "$PROTECTED_HOST" "$gateway" >> "$CONTROL_LOG_FILE" 2>&1 || route change -host "$PROTECTED_HOST" "$gateway" >> "$CONTROL_LOG_FILE" 2>&1 || true
        fi
        """
    }
}
