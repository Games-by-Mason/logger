# Logger

Logger for games.

* Writes to stderr
* Writes to a user provided writer for filesystem integration
* Writes to a ring buffer for editor integration
	* The ring buffer is also synced with Tracy if configured via [tracy_zig](https://github.com/Games-by-Mason/tracy_zig/)
