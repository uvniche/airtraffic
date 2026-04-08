import Darwin

/// Global storage for the saved terminal state so the C signal handler can access it.
var rawModeSaved = termios()
/// Global storage for stdin fd while raw mode is active.
var rawModeInputFD: Int32 = STDIN_FILENO
