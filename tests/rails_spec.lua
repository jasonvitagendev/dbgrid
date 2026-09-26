local H = _G.H
local rails = require("dbgrid.rails")
local util = require("dbgrid.util")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/config", "p")

H.describe("rails.database.yml", function()
  H.it("evaluates the ERB that database.yml files use", function()
    vim.env.DBGRID_T_HOST = "db.internal"
    H.eq(rails.strip_erb('host: <%= ENV["DBGRID_T_HOST"] %>'), "host: db.internal")
    H.eq(rails.strip_erb("user: <%= ENV.fetch('DBGRID_T_NOPE', 'app') %>"), "user: app")
    H.eq(rails.strip_erb('pool: <%= ENV.fetch("DBGRID_T_NOPE") { 5 } %>'), "pool: 5")
    H.eq(rails.strip_erb('x: <%= ENV["DBGRID_T_NOPE"] || "fallback" %>'), "x: fallback")
    H.eq(rails.strip_erb('<% if ENV["CI"] %>\n  host: ci\n<% end %>'), "\n  host: ci\n")
  end)
  H.it("parses the yaml subset with anchors and merges", function()
    util.write_file(
      tmp .. "/config/database.yml",
      table.concat({
        "default: &default",
        "  adapter: postgresql",
        "  encoding: unicode",
        '  host: <%= ENV["DBGRID_T_HOST"] %>',
        '  username: <%= ENV.fetch("DBGRID_T_USER", "app") %>',
        "  password: <%= ENV['DBGRID_T_PASSWORD'] %> # from the env",
        "",
        "development:",
        "  <<: *default",
        "  database: app_development",
        "  port: 5433",
        "",
        "test:",
        "  <<: *default",
        "  database: app_test",
        "",
        "production:",
        '  url: <%= ENV["DATABASE_URL"] %>',
      }, "\n")
    )
    local conns = rails.connections(tmp)
    H.eq(#conns, 2)
    H.eq(conns[1].name, "rails:development")
    H.eq(conns[1].url, "postgres://app@db.internal:5433/app_development")
    H.eq(conns[2].name, "rails:test")
    H.eq(conns[2].url, "postgres://app@db.internal/app_test")
    H.eq(conns[1].source, "config/database.yml")
  end)
  H.it("handles multi-database sqlite setups", function()
    util.write_file(
      tmp .. "/config/database.yml",
      table.concat({
        "default: &default",
        "  adapter: sqlite3",
        '  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>',
        "",
        "development:",
        "  primary:",
        "    <<: *default",
        "    database: storage/development.sqlite3",
        "  cable:",
        "    <<: *default",
        "    database: storage/development_cable.sqlite3",
        "",
        "test:",
        "  <<: *default",
        "  database: storage/test.sqlite3",
        "",
        "production:",
        "  <<: *default",
        "  database: storage/production.sqlite3",
      }, "\n")
    )
    local names = vim.tbl_map(function(c)
      return c.name .. " " .. c.url
    end, rails.connections(tmp))
    H.eq(names, {
      "rails:development.cable sqlite:" .. tmp .. "/storage/development_cable.sqlite3",
      "rails:development sqlite:" .. tmp .. "/storage/development.sqlite3",
      "rails:test sqlite:" .. tmp .. "/storage/test.sqlite3",
    })
    H.eq(#rails.connections(tmp, { "production" }), 1)
    H.eq(rails.connections(tmp, { "production" })[1].readonly, true)
    H.eq(rails.is_rails(tmp), false)
    util.write_file(tmp .. "/Gemfile", 'gem "rails"\n')
    H.eq(rails.is_rails(tmp), true)
    -- discovered through the connection registry
    require("dbgrid").setup({ storage = { data_dir = tmp .. "/data", mode = "data" } })
    local found = require("dbgrid.connections").discovered(tmp)
    H.truthy(#found >= 3)
    H.eq(found[#found].name, "rails:test")
    require("dbgrid").setup({ storage = { data_dir = tmp .. "/data", mode = "data" }, rails = { enabled = false } })
    H.eq(#require("dbgrid.connections").discovered(tmp), 0)
  end)
end)
