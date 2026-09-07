import Foundation

struct XrayTunScriptBuilder: Sendable {
    let installedXrayPath: String

    /// `installsIPv6Routes` mirrors the app's DNS/TUN policy: when the uplink has no
    /// global IPv6 the tunnel must not claim IPv6 either, so applications get an
    /// immediate "no route" instead of a connection that hangs inside the TUN.
    func makeStartScript(helperStateDirectoryPath: String, configPath: String, assetDirectoryPath: String, protectedHosts: [String], tunnelInterfaceName: String, outboundInterface: String, installsIPv6Routes: Bool) -> String {
        let q = shellQuote
        let pidFile = helperStateDirectoryPath + "/xray-tun.pid"
        let logFile = helperStateDirectoryPath + "/xray-tun.log"
        let protectedHostFile = helperStateDirectoryPath + "/xray-tun-protected-host"
        let protectedGatewayFile = helperStateDirectoryPath + "/xray-tun-protected-gateways"
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
        PROTECTED_GATEWAY_FILE=\(q(protectedGatewayFile))
        PROTECTED_DNS_FILE=\(q(protectedDNSFile))
        CONTROL_LOG_FILE=\(q(controlLogFile))
        XRAY=\(q(installedXrayPath))
        XRAY_ASSET_DIR=\(q(assetDirectoryPath))
        CONFIG=\(q(configPath))
        PROTECTED_HOSTS=\(q(protectedHosts.joined(separator: "\n")))
        TUN_INTERFACE_NAME=\(q(tunnelInterfaceName))
        OUTBOUND_INTERFACE=\(q(outboundInterface))
        INSTALL_IPV6_ROUTES=\(installsIPv6Routes ? 1 : 0)
        IPV6_ROUTES_INSTALLED=0

        cleanup_ipv6_routes_on_failure() {
            status=$?
            if [ "$status" -ne 0 ] && [ "$IPV6_ROUTES_INSTALLED" -eq 1 ]; then
                route delete -inet6 -net ::/1 >/dev/null 2>&1 || true
                route delete -inet6 -net 8000::/1 >/dev/null 2>&1 || true
            fi
        }
        trap cleanup_ipv6_routes_on_failure EXIT

        \(deleteHostRouteFunction())
        \(protectedHostFunctions())
        \(dnsRouteFunctions())
        \(directRouteFunctions())

        for helper_file in "$PID_FILE" "$LOG_FILE" "$LOG_FILE.1" "$PROTECTED_HOST_FILE" "$PROTECTED_GATEWAY_FILE" "$PROTECTED_DNS_FILE" "$CONTROL_LOG_FILE"; do
            [ ! -L "$helper_file" ] || rm -f "$helper_file"
        done

        touch "$CONTROL_LOG_FILE"
        chmod 600 "$CONTROL_LOG_FILE"
        printf '%s helper start requested for %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(printf '%s' "$PROTECTED_HOSTS" | tr '\n' ' ')" >> "$CONTROL_LOG_FILE"

        # Routes left by a previous session are removed before the host file is
        # rewritten, otherwise their hosts would no longer be known here.
        cleanup_host_routes
        cleanup_dns_routes
        cleanup_direct_routes

        route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
        route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
        route delete -inet6 -net ::/1 >/dev/null 2>&1 || true
        route delete -inet6 -net 8000::/1 >/dev/null 2>&1 || true

        rm -f "$PID_FILE"
        # The previous run's output is kept as one older generation: a session
        # that stopped working is usually followed by a reconnect, and truncating
        # here destroyed what that session had said before anyone could read it.
        if [ -s "$LOG_FILE" ]; then
            mv -f "$LOG_FILE" "$LOG_FILE.1"
        fi
        : > "$LOG_FILE"
        chmod 600 "$LOG_FILE"
        printf '%s\n' "$PROTECTED_HOSTS" > "$PROTECTED_HOST_FILE"
        chmod 600 "$PROTECTED_HOST_FILE"

        # Gateways are captured now, while the physical default routes are still
        # in place. Reading them back after the TUN exists would return the tunnel
        # itself and pin every proxy server inside the tunnel it carries.
        capture_host_gateways
        # Direct-route protection keeps following the first server's gateway, which
        # is the physical uplink's gateway in every ordinary topology.
        gateway=$(awk 'NR==1{print $2; exit}' "$PROTECTED_GATEWAY_FILE" 2>/dev/null || true)
        direct_ipv6_gateway=$(route -n get -inet6 default 2>/dev/null | awk '/gateway:/{print $2; exit}' || true)
        protect_host_routes
        protect_direct_routes "$gateway" "$direct_ipv6_gateway"
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

            protect_host_routes
            protect_dns_routes

            if ! kill -0 "$pid" >/dev/null 2>&1; then
                printf '%s pid %s exited during readiness wait\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" >> "$CONTROL_LOG_FILE"
                cleanup_host_routes
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
            cleanup_host_routes
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
            cleanup_host_routes
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
            cleanup_host_routes
            cleanup_dns_routes
            cleanup_direct_routes
            rm -f "$PID_FILE"
            exit 1
        fi

        if [ "$INSTALL_IPV6_ROUTES" -eq 1 ]; then
            IPV6_ROUTES_INSTALLED=1
        else
            printf '%s uplink %s has no global IPv6; leaving IPv6 routing untouched\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE"
        fi
        if [ "$INSTALL_IPV6_ROUTES" -eq 1 ] && {
           ! route add -inet6 -net ::/1 -interface "$tun_interface" >> "$CONTROL_LOG_FILE" 2>&1 ||
           ! route add -inet6 -net 8000::/1 -interface "$tun_interface" >> "$CONTROL_LOG_FILE" 2>&1; }; then
            reason="Teleport VPN could not install IPv6 default routes through Teleport's TUN."
            printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" >> "$CONTROL_LOG_FILE"
            printf '%s\n' "$reason" >&2
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
            route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
            route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
            cleanup_host_routes
            cleanup_dns_routes
            cleanup_direct_routes
            rm -f "$PID_FILE"
            exit 1
        fi

        protect_host_routes
        protect_direct_routes "$gateway" "$direct_ipv6_gateway"
        protect_dns_routes

        public_interface_low=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
        public_interface_high=$(route -n get 129.0.0.1 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
        tunneled_protected_host=$(first_tunneled_protected_host)
        printf '%s pid %s running, tun %s, public low route %s, public high route %s, protected hosts %s, tunneled %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" "$tun_interface" "${public_interface_low:-unknown}" "${public_interface_high:-unknown}" "$(printf '%s' "$PROTECTED_HOSTS" | tr '\n' ' ')" "${tunneled_protected_host:-none}" >> "$CONTROL_LOG_FILE"

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
                cleanup_host_routes
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
                cleanup_host_routes
                cleanup_dns_routes
                cleanup_direct_routes
                rm -f "$PID_FILE"
                exit 1
                ;;
        esac

        if [ -n "$tunneled_protected_host" ]; then
            reason="Teleport VPN could not keep the proxy server route outside the tunnel. Disconnect other VPN apps and try again, or use System Proxy mode."
            printf '%s %s (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" "$tunneled_protected_host" >> "$CONTROL_LOG_FILE"
            printf '%s\n' "$reason" >&2
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
            route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
            route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
            cleanup_host_routes
            cleanup_dns_routes
            cleanup_direct_routes
            rm -f "$PID_FILE"
            exit 1
        fi

        printf '%s pid %s ready\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" >> "$CONTROL_LOG_FILE"
        exit 0
        """
    }

    func makeStopScript(helperStateDirectoryPath: String, protectedHosts: [String]?, outboundInterface: String?) -> String {
        let q = shellQuote
        let pidFile = helperStateDirectoryPath + "/xray-tun.pid"
        let protectedHostFile = helperStateDirectoryPath + "/xray-tun-protected-host"
        let protectedGatewayFile = helperStateDirectoryPath + "/xray-tun-protected-gateways"
        let protectedDNSFile = helperStateDirectoryPath + "/xray-tun-protected-dns"
        let configFile = helperStateDirectoryPath + "/xray-tun-config.json"
        let controlLogFile = helperStateDirectoryPath + "/xray-tun-control.log"

        var commands: [String] = []
        commands.append("OUTBOUND_INTERFACE=\(q(outboundInterface ?? ""))")
        commands.append("PROTECTED_HOST_FILE=\(q(protectedHostFile))")
        commands.append("PROTECTED_GATEWAY_FILE=\(q(protectedGatewayFile))")
        commands.append("PROTECTED_DNS_FILE=\(q(protectedDNSFile))")
        commands.append("CONTROL_LOG_FILE=\(q(controlLogFile))")
        commands.append(deleteHostRouteFunction())
        commands.append(protectedHostFunctions())
        commands.append(dnsRouteFunctions())
        commands.append(directRouteFunctions())
        commands.append("for helper_file in \(q(pidFile)) \(q(protectedHostFile)) \(q(protectedGatewayFile)) \(q(protectedDNSFile)) \(q(controlLogFile)); do [ ! -L \"$helper_file\" ] || rm -f \"$helper_file\"; done")
        commands.append("touch \(q(controlLogFile)); chmod 600 \(q(controlLogFile))")
        commands.append("printf '%s helper stop requested\\n' \"$(date '+%Y-%m-%d %H:%M:%S')\" >> \(q(controlLogFile))")
        // The client's list and the helper's own file are both used: a stop that
        // follows a helper restart has only the file, and one that follows a
        // partial start may have hosts the file never received.
        for protectedHost in (protectedHosts ?? []) where !protectedHost.isEmpty {
            commands.append("delete_host_route \(q(protectedHost))")
        }
        commands.append("cleanup_host_routes")
        commands.append("cleanup_dns_routes")
        commands.append("cleanup_direct_routes")
        // TODO(gpt-5.6-sol): These destination-only deletes are not tied to a
        // Teleport session, and `|| true` hides cleanup failures from the client.
        // Delete only journaled routes and report any route that could not be removed.
        commands.append("route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true")
        commands.append("route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true")
        commands.append("route delete -inet6 -net ::/1 >/dev/null 2>&1 || true")
        commands.append("route delete -inet6 -net 8000::/1 >/dev/null 2>&1 || true")
        commands.append("rm -f \(q(pidFile))")
        commands.append("rm -f \(q(protectedHostFile))")
        commands.append("rm -f \(q(protectedGatewayFile))")
        commands.append("rm -f \(q(protectedDNSFile))")
        commands.append("rm -f \(q(configFile))")
        return commands.joined(separator: "; ")
    }

    private func deleteHostRouteFunction() -> String {
        """
        delete_host_route() {
            host="$1"
            route_family=""
            case "$host" in *:*) route_family="-inet6" ;; esac
            current_interface=$(route -n get $route_family "$host" 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
            for scoped_interface in "${OUTBOUND_INTERFACE:-}" "$current_interface" en0 en1 en2 bridge100; do
                [ -n "$scoped_interface" ] || continue
                i=0
                while route delete $route_family -host -ifscope "$scoped_interface" "$host" >/dev/null 2>&1; do
                    i=$((i + 1))
                    [ "$i" -ge 10 ] && break
                done
            done
            i=0
            while route delete $route_family -host "$host" >/dev/null 2>&1; do
                i=$((i + 1))
                [ "$i" -ge 10 ] && break
            done
        }
        """
    }

    private func dnsRouteFunctions() -> String {
        """
        cleanup_dns_routes() {
            if [ -f "$PROTECTED_DNS_FILE" ]; then
                while IFS= read -r dns_server; do
                    [ -n "$dns_server" ] || continue
                    delete_host_route "$dns_server"
                done < "$PROTECTED_DNS_FILE"
            fi
            rm -f "$PROTECTED_DNS_FILE"
        }

        # DNS follows the TUN default routes. Keep this no-op for shared start/stop
        # sequencing and to clean up bypass markers left by older helper versions.
        protect_dns_routes() {
            :
        }
        """
    }

    private func directRouteFunctions() -> String {
        """
        cleanup_direct_routes() {
            [ -n "${OUTBOUND_INTERFACE:-}" ] || return 0
            route delete -net 0.0.0.0/1 -ifscope "$OUTBOUND_INTERFACE" >/dev/null 2>&1 || true
            route delete -net 128.0.0.0/1 -ifscope "$OUTBOUND_INTERFACE" >/dev/null 2>&1 || true
            route delete -inet6 -net ::/1 -ifscope "$OUTBOUND_INTERFACE" >/dev/null 2>&1 || true
            route delete -inet6 -net 8000::/1 -ifscope "$OUTBOUND_INTERFACE" >/dev/null 2>&1 || true
        }

        protect_direct_routes() {
            direct_gateway="$1"
            direct_ipv6_gateway="${2:-}"
            [ "${INSTALL_IPV6_ROUTES:-1}" -eq 1 ] || direct_ipv6_gateway=""
            [ -n "${OUTBOUND_INTERFACE:-}" ] || return 0
            [ "$OUTBOUND_INTERFACE" != "auto" ] || return 0
            [ -n "$direct_gateway" ] || return 0

            cleanup_direct_routes
            route add -net 0.0.0.0/1 "$direct_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || \
                route change -net 0.0.0.0/1 "$direct_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || true
            route add -net 128.0.0.0/1 "$direct_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || \
                route change -net 128.0.0.0/1 "$direct_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || true
            if [ -n "$direct_ipv6_gateway" ]; then
                route add -inet6 -net ::/1 "$direct_ipv6_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || \
                    route change -inet6 -net ::/1 "$direct_ipv6_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || true
                route add -inet6 -net 8000::/1 "$direct_ipv6_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || \
                    route change -inet6 -net 8000::/1 "$direct_ipv6_gateway" -ifscope "$OUTBOUND_INTERFACE" >> "$CONTROL_LOG_FILE" 2>&1 || true
            fi
        }
        """
    }

    /// One host route per proxy server the session dials, all driven from the
    /// helper-owned host file so start, readiness re-application, failure cleanup
    /// and stop iterate the same list.
    private func protectedHostFunctions() -> String {
        """
        host_route_family() {
            case "$1" in *:*) printf '%s' "-inet6" ;; *) printf '' ;; esac
        }

        cleanup_host_routes() {
            [ -f "$PROTECTED_HOST_FILE" ] || return 0
            while IFS= read -r protected_host; do
                [ -n "$protected_host" ] || continue
                delete_host_route "$protected_host"
            done < "$PROTECTED_HOST_FILE"
        }

        capture_host_gateways() {
            : > "$PROTECTED_GATEWAY_FILE"
            chmod 600 "$PROTECTED_GATEWAY_FILE"
            while IFS= read -r protected_host; do
                [ -n "$protected_host" ] || continue
                host_family=$(host_route_family "$protected_host")
                delete_host_route "$protected_host"
                host_gateway=$(route -n get $host_family "$protected_host" 2>/dev/null | awk '/gateway:/{print $2; exit}')
                [ -n "$host_gateway" ] || continue
                printf '%s %s\n' "$protected_host" "$host_gateway" >> "$PROTECTED_GATEWAY_FILE"
            done < "$PROTECTED_HOST_FILE"
        }

        protect_host_routes() {
            [ -f "$PROTECTED_GATEWAY_FILE" ] || return 0
            while IFS=' ' read -r protected_host host_gateway; do
                [ -n "$protected_host" ] || continue
                [ -n "$host_gateway" ] || continue
                host_family=$(host_route_family "$protected_host")
                delete_host_route "$protected_host"
                route add $host_family -host "$protected_host" "$host_gateway" >> "$CONTROL_LOG_FILE" 2>&1 || route change $host_family -host "$protected_host" "$host_gateway" >> "$CONTROL_LOG_FILE" 2>&1 || true
            done < "$PROTECTED_GATEWAY_FILE"
        }

        # Prints the first protected server that ended up routed through a tunnel,
        # which would mean its own transport runs inside the tunnel it carries.
        first_tunneled_protected_host() {
            [ -f "$PROTECTED_HOST_FILE" ] || return 0
            while IFS= read -r protected_host; do
                [ -n "$protected_host" ] || continue
                host_family=$(host_route_family "$protected_host")
                protected_interface=$(route -n get $host_family "$protected_host" 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
                case "$protected_interface" in
                    utun*) printf '%s' "$protected_host"; return 0 ;;
                esac
            done < "$PROTECTED_HOST_FILE"
            return 0
        }
        """
    }
}
