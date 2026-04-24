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

    app.migrations.add(CreateFeedSources())
    app.migrations.add(CreateFeedItems())
    app.migrations.add(CreateInterestProfile())
    app.migrations.add(CreateItemScores())
    app.migrations.add(CreateCaptures())
    app.migrations.add(AddCatchupCache())
    app.migrations.add(CreateEngagements())

    app.asyncCommands.use(SeedFeedsCommand(), as: "seed-feeds")
    app.asyncCommands.use(IngestCommand(), as: "ingest")
    app.asyncCommands.use(ScoreCommand(), as: "score")
    app.asyncCommands.use(CatchupAllCommand(), as: "catchup-all")

    // Generous body limit for capture text (default is 1MB, keep that)
    app.routes.defaultMaxBodySize = "1mb"

    // register routes
    try routes(app)
}
