import Foundation

/// APN 草稿保留原厂字段，编辑时不覆盖未展示的扩展属性。
struct APNProfile: Identifiable {
    var values: JSONObject
    var id: String {
        values.string("profileId") ?? ""
    }
    var name: String {
        values.string("profilename") ?? "未命名"
    }
    var apn: String {
        values.string("wanapn") ?? ""
    }
}

extension WebSSHAPI {
    func apnProfiles() async throws -> [APNProfile] {
        let result = try await read("zwrt_apn_object", "get_manu_apn_list")
        return (result.raw["apnListArray"] as? [[String: Any]] ?? []).map {
            APNProfile(values: JSONObject($0))
        }
    }

    func saveAPN(_ profile: APNProfile) async throws {
        guard !profile.name.isEmpty, profile.name.count <= 32, !profile.apn.isEmpty, profile.apn.count <= 100,
            profile.apn.utf8.allSatisfy({
                (45...46).contains($0) || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            })
        else {
            throw ManagementError.invalid("请填写名称和有效 APN；APN 仅允许字母、数字、点和连字符。")
        }
        _ = try await rpc("zwrt_apn_object", profile.id.isEmpty ? "add_manu_apn" : "modify_manu_apn", params: profile.values)
        let actual = try await apnProfiles()
        guard actual.contains(where: { $0.name == profile.name && $0.apn == profile.apn }) else {
            throw ManagementError.unconfirmed("APN 已提交，但回读没有发现相同配置。")
        }
    }

    func selectAPN(_ id: String?) async throws {
        let previous = try await read("zwrt_apn_object", "get_apn_mode").int("apn_mode")
        guard let previous else {
            throw ManagementError.unconfirmed("无法读取当前 APN 模式。")
        }
        _ = try await rpc("zwrt_apn_object", "set_apn_mode", params: JSONObject(["apn_mode": id == nil ? 0 : 1]))
        do {
            if let id {
                _ = try await rpc("zwrt_apn_object", "enable_manu_apn_id", params: JSONObject(["profileId": id]))
                let selected = try await read("zwrt_apn_object", "get_enabled_manu_apn_id")
                guard selected.string("profileId") == id else {
                    throw ManagementError.unconfirmed("APN 选择结果不一致。")
                }
            }
            guard try await read("zwrt_apn_object", "get_apn_mode").int("apn_mode") == (id == nil ? 0 : 1) else {
                throw ManagementError.unconfirmed("APN 模式回读不一致。")
            }
        } catch {
            _ = try? await rpc("zwrt_apn_object", "set_apn_mode", params: JSONObject(["apn_mode": previous]))
            throw error
        }
    }

    func setRoaming(_ enabled: Bool) async throws {
        let params = JSONObject(["source_module": "web", "cid": 1])
        let old = try await rpc("zwrt_data", "get_wwaniface", params: params)
        guard let mode = old.int("connect_mode") else {
            throw ManagementError.unconfirmed("无法读取蜂窝连接模式。")
        }
        _ = try await rpc(
            "zwrt_data", "set_wwaniface",
            params: JSONObject([
                "source_module": "web", "cid": 1, "connect_mode": mode, "roam_enable": enabled ? 1 : 0,
            ]))
        guard try await rpc("zwrt_data", "get_wwaniface", params: params).int("roam_enable") == (enabled ? 1 : 0) else {
            throw ManagementError.unconfirmed("漫游开关回读不一致，请刷新检查。")
        }
    }

    func setDirectPower(_ enabled: Bool) async throws {
        let value = enabled ? "enable" : "disable"
        _ = try await rpc("zwrt_bsp.charger", "set", params: JSONObject(["direct_power_supply_mode": value]))
        guard try await read("zwrt_bsp.charger", "list").string("direct_power_supply_mode") == value else {
            throw ManagementError.unconfirmed("直供电开关回读不一致。")
        }
    }

    func usbMode() async throws -> String {
        let result = try await runMaintenanceScript(
            """
            for link in /sys/kernel/config/usb_gadget/g1/configs/c.1/f*; do
                readlink "$link"
            done
            """)
        if result.contains("gsi.ecm") {
            return "ecm"
        }
        if result.contains("gsi.rndis") {
            return "rndis"
        }
        if result.contains("ncm.0") {
            return "ncm"
        }
        return "storage"
    }

    /// B28 没有 USB set 方法。仅替换网络 function，保留 ADB/诊断链接；异常时恢复原组合。
    /// 这是当前连接的临时模式，设备重启会由原厂启动流程重新配置。
    func setUSBMode(_ mode: String) async throws {
        guard ["ecm", "rndis"].contains(mode) else {
            throw ManagementError.invalid("不支持的 USB 模式。")
        }
        let function = mode == "ecm" ? "gsi.ecm" : "gsi.rndis"
        let deviceClass = mode == "ecm" ? "0x02" : "0x00"
        let interface = mode == "ecm" ? "ecm0" : "rndis0"
        _ = try await runMaintenanceScript(
            """
            set -eu
            cd /sys/kernel/config/usb_gadget/g1
            test -d functions/\(function)
            test "$(cat /tmp/usb_bind_in_progress 2>/dev/null || true)" != start
            test "$(cat /sys/bus/platform/devices/a600000.ssusb/mode)" != host
            mkdir /tmp/u60-usb-lock
            # 快照尚未完成时只清理临时资源，不能使用不完整快照恢复 USB。
            saved=''
            trap 'test -z "$saved" || rm -rf "$saved"; rmdir /tmp/u60-usb-lock' EXIT
            saved=$(mktemp -d /tmp/u60-usb.XXXXXX)
            cat UDC > "$saved/udc"
            cat bDeviceClass > "$saved/class"
            ls /sys/class/net/br-lan/brif > "$saved/bridge"
            for link in configs/c.1/f*; do
                test -L "$link" || continue
                readlink "$link" > "$saved/$(basename "$link")"
            done
            restore() {
                if [ -f "$saved/added" ]; then
                    brctl delif br-lan "$(cat "$saved/added")" 2>/dev/null || true
                fi
                echo '' > UDC
                for link in configs/c.1/f*; do test ! -L "$link" || rm "$link"; done
                for old in "$saved"/f*; do
                    test -f "$old" || continue
                    ln -s "$(cat "$old")" "configs/c.1/$(basename "$old")"
                done
                cat "$saved/class" > bDeviceClass
                cat "$saved/udc" > UDC
                sleep 1
                while read old; do
                    case "$old" in
                        ecm*|rndis*|usb*|ncm*)
                            ip link set "$old" up 2>/dev/null || true
                            brctl addif br-lan "$old" 2>/dev/null || true
                            ;;
                    esac
                done < "$saved/bridge"
            }
            finish() {
                code=$?
                trap - EXIT
                if [ "$code" != 0 ]; then restore || true; fi
                rm -rf "$saved"
                rmdir /tmp/u60-usb-lock
                exit "$code"
            }
            trap finish EXIT
            echo '' > UDC
            for link in configs/c.1/f*; do
                case "$(readlink "$link" || true)" in
                    *gsi.ecm|*gsi.rndis|*ncm.0|*rndis.rndis|*ecm.ecm) rm "$link" ;;
                esac
            done
            slot=1
            while [ -e "configs/c.1/f$slot" ]; do slot=$((slot + 1)); done
            ln -s ../../functions/\(function) "configs/c.1/f$slot"
            echo \(deviceClass) > bDeviceClass
            controller=$(cat "$saved/udc")
            if [ -z "$controller" ]; then controller=$(ls /sys/class/udc | head -n 1); fi
            test -n "$controller"
            echo "$controller" > UDC
            test "$(cat UDC)" = "$controller"
            retry=0
            while [ ! -d /sys/class/net/\(interface) ] && [ "$retry" -lt 8 ]; do
                sleep 1
                retry=$((retry + 1))
            done
            test -d /sys/class/net/\(interface)
            ip link set \(interface) up
            if [ ! -d /sys/class/net/br-lan/brif/\(interface) ]; then
                echo \(interface) > "$saved/added"
                brctl addif br-lan \(interface)
            fi
            test -d /sys/class/net/br-lan/brif/\(interface)
            """)
        guard try await usbMode() == mode else {
            throw ManagementError.unconfirmed("USB 模式回读不一致。请通过 Wi-Fi 重新检查。")
        }
    }
}
