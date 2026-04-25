import Fluent
import FluentPostgresDriver
import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    let postgresConfig = SQLPostgresConfiguration(
        hostname: Environment.get("DATABASE_HOST") ?? "localhost",
        port: Int(Environment.get("DATABASE_PORT") ?? "5432") ?? 5432,
        username: Environment.get("DATABASE_USERNAME") ?? "newsfeed",
        password: Environment.get("DATABASE_PASSWORD") ?? "",
        database: Environment.get("DATABASE_NAME") ?? "newsfeed",
        tls: .disable
    )
    app.databases.use(.postgres(configuration: postgresConfig), as: .psql)

    // Migrations (order matters: later migrations reference earlier tables)
    app.migrations.add(CreateFeedSources())
    app.migrations.add(CreateFeedItems())
    app.migrations.add(CreateInterestProfile())
    app.migrations.add(CreateItemScores())
    app.migrations.add(CreateCaptures())
    app.migrations.add(AddCatchupCache())
    app.migrations.add(CreateEngagements())
    app.migrations.add(AddDupOfItemIdToItemScores())
    app.migrations.add(CreateUserItemScores())

    // Auth-related migrations (Phase 1 auth)
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateUserProfiles())
    app.migrations.add(CreateInvites())
    app.migrations.add(AddUserIdToEngagements())
    app.migrations.add(AddUserIdToCaptures())
    app.migrations.add(SessionRecord.migration)  // Fluent-backed session store

    // Commands
    app.asyncCommands.use(SeedFeedsCommand(), as: "seed-feeds")
    app.asyncCommands.use(IngestCommand(), as: "ingest")
    app.asyncCommands.use(ScoreCommand(), as: "score")
    app.asyncCommands.use(CatchupAllCommand(), as: "catchup-all")
    app.asyncCommands.use(CreateInviteCommand(), as: "create-invite")
    app.asyncCommands.use(ReleaseInviteCommand(), as: "release-invite")

    // Sessions + authentication middleware. Sessions first, then the User
    // authenticator that reads session → User. Routes opt in to protection
    // via a grouped middleware (User.redirectMiddleware).
    app.sessions.use(.fluent)
    app.middleware.use(app.sessions.middleware)
    app.middleware.use(User.sessionAuthenticator())

    // Generous body limit for capture text (default is 1MB, keep that)
    app.routes.defaultMaxBodySize = "1mb"

    // register routes
    try routes(app)
}
