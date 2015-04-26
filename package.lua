return {
  name = "luvit-poller",
  version = "0.2.0",
  private = true,
  description = "simple polling client that respects headers",
  author = "squeek",
  dependencies = {
    "luvit/luvit@2.1.0"
  },
  files = {
    "!tests",
    "**.lua"
  }
}
