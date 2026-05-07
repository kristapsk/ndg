pub const Chain = enum {
    main,
    test,
    signet,

    pub fn lndName(self: Chain) []const u8 {
        return switch (self) {
            .main => "mainnet",
            .test => "testnet",
            .signet => "signet",
        };
    }

    pub fn bitcoindRpcPort(self: Chain) u16 {
        return switch (self) {
            .main => 8332,
            .test => 18332,
            .signet => 38332,
        };
    }

    pub fn bitcoindZmqBlockPort(self: Chain) u16 {
        return switch (self) {
            .main => 8331,
            .test => 18331,
            .signet => 38331,
        };
    }

    pub fn bitcoindZmqTxPort(self: Chain) u16 {
        return switch (self) {
            .main => 8330,
            .test => 18330,
            .signet => 38330,
        };
    }
};
