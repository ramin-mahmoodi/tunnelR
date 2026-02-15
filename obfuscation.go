package httpmux

// ObfsConfig controls traffic obfuscation behavior.
// Padding is applied inside EncryptedConn before encryption.
// Delay (timing jitter) is applied after sending large packets.
type ObfsConfig struct {
	Enabled     bool `yaml:"enabled"`
	MinPadding  int  `yaml:"min_padding"`
	MaxPadding  int  `yaml:"max_padding"`
	MinDelayMS  int  `yaml:"min_delay_ms"`
	MaxDelayMS  int  `yaml:"max_delay_ms"`
	BurstChance int  `yaml:"burst_chance"`
}
