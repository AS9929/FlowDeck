import Foundation

/// F50 射频协议适配：身份约束、并发检测、单次提交和结果回读。
extension UFIClient: UFIRadioAPI {
    func radioState(password: String) async throws -> UFIRadioState {
        try await verifyWifiFirmware()
        try await authenticateFactory(password: password)
        let settings = try await wifiQuery("lte_band_lock,nr_band_lock,locked_cell_info")
        // 支持列表失败不能回落到猜测的 5G 频段，但仍允许查看状态、解除限制。
        let support = try? await request("api/getSupportNrBandList", query: [URLQueryItem(name: "slot", value: "0")])
        let values = support?.raw["band_list"] as? [Int]
        let supported = values.flatMap { values -> Set<Int>? in
            guard !values.isEmpty, values.allSatisfy({ (1...1024).contains($0) }) else { return nil }
            return Set(values)
        }
        return try UFIRadioState(settings, supportedNR: supported)
    }

    func setRadioBands(
        _ bands: Set<Int>, technology: UFIRadioTechnology,
        replacing original: UFIRadioState, password: String
    ) async throws {
        try beginRadioWrite()
        defer { radioWriteRunning = false }
        let current = try await radioState(password: password)
        guard current == original else {
            throw ManagementError.unconfirmed("射频状态已被修改，请刷新后再操作。")
        }
        let form = try current.bandForm(bands, technology: technology)
        if current.selected(technology) == bands { return }
        try await submitFactory(form, password: password)
        try await confirmRadio(password: password) { actual in
            actual.selected(technology) == bands
                && actual.selected(technology == .lte ? .nr : .lte)
                    == original.selected(technology == .lte ? .nr : .lte)
                && actual.cells == original.cells
        }
    }

    func setRadioCell(_ cell: UFILockedCell?, replacing original: UFIRadioState, password: String) async throws {
        try beginRadioWrite()
        defer { radioWriteRunning = false }
        let form = try cell?.form() ?? ["goformId": "UNLOCK_ALL_CELL"]
        guard try await radioState(password: password) == original else {
            throw ManagementError.unconfirmed("射频状态已被修改，请刷新后再操作。")
        }
        if cell == nil && original.cells.isEmpty { return }
        // 不覆盖现有多个锁定项；用户必须先明确解除，然后添加目标小区。
        guard cell == nil || original.cells.isEmpty else {
            throw ManagementError.invalid("请先解除现有小区锁定，再添加新的锁定目标。")
        }
        try await submitFactory(form, password: password)
        try await confirmRadio(password: password) { actual in
            actual.cells == (cell.map { [$0] } ?? []) && actual.lte == original.lte && actual.nr == original.nr
        }
    }

    private func beginRadioWrite() throws {
        guard expectedFingerprint != nil else { throw ManagementError.deviceChanged }
        guard !radioWriteRunning else { throw ManagementError.unconfirmed("射频操作正在执行，请等待回读。") }
        radioWriteRunning = true
    }

    /// 只重读、不重写；链路中断保留结果未知状态，不能自动重复锁频。
    private func confirmRadio(password: String, matches: (UFIRadioState) -> Bool) async throws {
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(700)) }
            if matches(try await radioState(password: password)) { return }
        }
        throw ManagementError.unconfirmed("已提交射频设置，回读尚未一致。请刷新核对，必要时恢复自动或解除小区锁定。")
    }
}
