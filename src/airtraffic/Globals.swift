import Darwin

/// Global storage for the saved terminal state so the C signal handler can access it.
var rawModeSaved = termios()
