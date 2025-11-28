# Logger

Logger for games.

* Stores ring buffer of past logs for integration with engine UI
* Sends logs to Tracy if configured via [tracy_zig](https://github.com/Games-by-Mason/tracy_zig/)
* Writes logs to a user provided writer for filesystem integration
