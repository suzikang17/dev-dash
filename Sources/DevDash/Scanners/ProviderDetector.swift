import Foundation

/// Detect third-party providers used by a project by scanning package.json
/// dependencies and .env keys against a registry of known services.
enum ProviderDetector {
    struct Signature {
        let name: String
        let category: ProviderCategory
        let dashboardURL: String?
        let npmPackages: [String]
        let envPrefixes: [String]
    }

    static let signatures: [Signature] = [
        // Hosting
        .init(name: "Vercel",     category: .hosting,    dashboardURL: "https://vercel.com/dashboard",
              npmPackages: ["@vercel/analytics", "@vercel/blob", "@vercel/edge-config", "@vercel/postgres", "@vercel/kv"],
              envPrefixes: ["VERCEL_"]),
        .init(name: "Netlify",    category: .hosting,    dashboardURL: "https://app.netlify.com/",
              npmPackages: ["@netlify/functions", "netlify-cli"],
              envPrefixes: ["NETLIFY_"]),
        .init(name: "Cloudflare", category: .cdn,        dashboardURL: "https://dash.cloudflare.com/",
              npmPackages: ["wrangler", "@cloudflare/workers-types"],
              envPrefixes: ["CLOUDFLARE_", "CF_"]),
        .init(name: "Fly.io",     category: .hosting,    dashboardURL: "https://fly.io/dashboard",
              npmPackages: [], envPrefixes: ["FLY_"]),
        .init(name: "Railway",    category: .hosting,    dashboardURL: "https://railway.app/dashboard",
              npmPackages: [], envPrefixes: ["RAILWAY_"]),
        .init(name: "Render",     category: .hosting,    dashboardURL: "https://dashboard.render.com",
              npmPackages: [], envPrefixes: ["RENDER_"]),
        .init(name: "AWS",        category: .hosting,    dashboardURL: "https://console.aws.amazon.com/",
              npmPackages: ["aws-sdk", "@aws-sdk/client-s3", "@aws-sdk/client-dynamodb", "@aws-sdk/client-ses"],
              envPrefixes: ["AWS_"]),
        .init(name: "GCP",        category: .hosting,    dashboardURL: "https://console.cloud.google.com/",
              npmPackages: ["@google-cloud/storage", "@google-cloud/firestore"],
              envPrefixes: ["GCP_", "GOOGLE_"]),

        // Database / data
        .init(name: "Supabase",   category: .database,   dashboardURL: "https://supabase.com/dashboard",
              npmPackages: ["@supabase/supabase-js", "@supabase/auth-helpers-nextjs"],
              envPrefixes: ["SUPABASE_", "NEXT_PUBLIC_SUPABASE_"]),
        .init(name: "Neon",       category: .database,   dashboardURL: "https://console.neon.tech/",
              npmPackages: ["@neondatabase/serverless"],
              envPrefixes: ["NEON_"]),
        .init(name: "Planetscale",category: .database,   dashboardURL: "https://app.planetscale.com/",
              npmPackages: ["@planetscale/database"],
              envPrefixes: ["PLANETSCALE_", "DATABASE_URL"]),
        .init(name: "PostgreSQL", category: .database,   dashboardURL: nil,
              npmPackages: ["pg", "postgres"],
              envPrefixes: ["POSTGRES_"]),
        .init(name: "MongoDB",    category: .database,   dashboardURL: "https://cloud.mongodb.com/",
              npmPackages: ["mongodb", "mongoose"],
              envPrefixes: ["MONGO_", "MONGODB_"]),
        .init(name: "Redis",      category: .database,   dashboardURL: nil,
              npmPackages: ["redis", "ioredis"],
              envPrefixes: ["REDIS_"]),
        .init(name: "Upstash",    category: .database,   dashboardURL: "https://console.upstash.com/",
              npmPackages: ["@upstash/redis", "@upstash/ratelimit"],
              envPrefixes: ["UPSTASH_"]),
        .init(name: "Turso",      category: .database,   dashboardURL: "https://app.turso.tech/",
              npmPackages: ["@libsql/client"],
              envPrefixes: ["TURSO_"]),
        .init(name: "Prisma",     category: .database,   dashboardURL: "https://cloud.prisma.io/",
              npmPackages: ["prisma", "@prisma/client"],
              envPrefixes: []),
        .init(name: "Drizzle",    category: .database,   dashboardURL: nil,
              npmPackages: ["drizzle-orm"],
              envPrefixes: []),

        // Payments
        .init(name: "Stripe",     category: .payments,   dashboardURL: "https://dashboard.stripe.com/",
              npmPackages: ["stripe", "@stripe/stripe-js", "@stripe/react-stripe-js"],
              envPrefixes: ["STRIPE_"]),
        .init(name: "Lemon Squeezy", category: .payments, dashboardURL: "https://app.lemonsqueezy.com/",
              npmPackages: ["@lemonsqueezy/lemonsqueezy.js"],
              envPrefixes: ["LEMONSQUEEZY_"]),
        .init(name: "Paddle",     category: .payments,   dashboardURL: "https://vendors.paddle.com/",
              npmPackages: ["@paddle/paddle-js"],
              envPrefixes: ["PADDLE_"]),

        // Email
        .init(name: "Resend",     category: .email,      dashboardURL: "https://resend.com/overview",
              npmPackages: ["resend"],
              envPrefixes: ["RESEND_"]),
        .init(name: "SendGrid",   category: .email,      dashboardURL: "https://app.sendgrid.com/",
              npmPackages: ["@sendgrid/mail"],
              envPrefixes: ["SENDGRID_"]),
        .init(name: "Mailgun",    category: .email,      dashboardURL: "https://app.mailgun.com/",
              npmPackages: ["mailgun-js", "mailgun.js"],
              envPrefixes: ["MAILGUN_"]),
        .init(name: "Postmark",   category: .email,      dashboardURL: "https://account.postmarkapp.com/",
              npmPackages: ["postmark"],
              envPrefixes: ["POSTMARK_"]),
        .init(name: "Loops",      category: .email,      dashboardURL: "https://app.loops.so/",
              npmPackages: ["loops"],
              envPrefixes: ["LOOPS_"]),

        // AI
        .init(name: "OpenAI",     category: .ai,         dashboardURL: "https://platform.openai.com/usage",
              npmPackages: ["openai", "@ai-sdk/openai"],
              envPrefixes: ["OPENAI_"]),
        .init(name: "Anthropic",  category: .ai,         dashboardURL: "https://console.anthropic.com/usage",
              npmPackages: ["@anthropic-ai/sdk", "@ai-sdk/anthropic"],
              envPrefixes: ["ANTHROPIC_"]),
        .init(name: "OpenRouter", category: .ai,         dashboardURL: "https://openrouter.ai/activity",
              npmPackages: [],
              envPrefixes: ["OPENROUTER_"]),
        .init(name: "Replicate",  category: .ai,         dashboardURL: "https://replicate.com/account/billing",
              npmPackages: ["replicate"],
              envPrefixes: ["REPLICATE_"]),
        .init(name: "Groq",       category: .ai,         dashboardURL: "https://console.groq.com/",
              npmPackages: ["groq-sdk", "@ai-sdk/groq"],
              envPrefixes: ["GROQ_"]),
        .init(name: "Vercel AI SDK", category: .ai,      dashboardURL: nil,
              npmPackages: ["ai"],
              envPrefixes: []),

        // Auth
        .init(name: "Clerk",      category: .auth,       dashboardURL: "https://dashboard.clerk.com/",
              npmPackages: ["@clerk/nextjs", "@clerk/clerk-react", "@clerk/clerk-sdk-node"],
              envPrefixes: ["CLERK_", "NEXT_PUBLIC_CLERK_"]),
        .init(name: "Auth0",      category: .auth,       dashboardURL: "https://manage.auth0.com/",
              npmPackages: ["@auth0/nextjs-auth0", "auth0"],
              envPrefixes: ["AUTH0_"]),
        .init(name: "NextAuth",   category: .auth,       dashboardURL: nil,
              npmPackages: ["next-auth"],
              envPrefixes: ["NEXTAUTH_"]),
        .init(name: "Better Auth",category: .auth,       dashboardURL: nil,
              npmPackages: ["better-auth"],
              envPrefixes: ["BETTER_AUTH_"]),

        // Analytics / monitoring
        .init(name: "PostHog",    category: .analytics,  dashboardURL: "https://app.posthog.com/",
              npmPackages: ["posthog-js", "posthog-node"],
              envPrefixes: ["POSTHOG_", "NEXT_PUBLIC_POSTHOG_"]),
        .init(name: "Mixpanel",   category: .analytics,  dashboardURL: "https://mixpanel.com/",
              npmPackages: ["mixpanel-browser", "mixpanel"],
              envPrefixes: ["MIXPANEL_"]),
        .init(name: "Plausible",  category: .analytics,  dashboardURL: "https://plausible.io/sites",
              npmPackages: ["plausible-tracker"],
              envPrefixes: ["PLAUSIBLE_"]),
        .init(name: "Segment",    category: .analytics,  dashboardURL: "https://app.segment.com/",
              npmPackages: ["analytics-node", "@segment/analytics-next"],
              envPrefixes: ["SEGMENT_"]),
        .init(name: "Sentry",     category: .monitoring, dashboardURL: "https://sentry.io/",
              npmPackages: ["@sentry/node", "@sentry/nextjs", "@sentry/react"],
              envPrefixes: ["SENTRY_"]),
        .init(name: "Datadog",    category: .monitoring, dashboardURL: "https://app.datadoghq.com/",
              npmPackages: ["dd-trace", "@datadog/browser-rum"],
              envPrefixes: ["DD_", "DATADOG_"]),
        .init(name: "Axiom",      category: .monitoring, dashboardURL: "https://app.axiom.co/",
              npmPackages: ["@axiomhq/js"],
              envPrefixes: ["AXIOM_"]),

        // Storage / CDN / search / other
        .init(name: "Cloudinary", category: .storage,    dashboardURL: "https://console.cloudinary.com/",
              npmPackages: ["cloudinary"],
              envPrefixes: ["CLOUDINARY_"]),
        .init(name: "Algolia",    category: .search,     dashboardURL: "https://dashboard.algolia.com/",
              npmPackages: ["algoliasearch"],
              envPrefixes: ["ALGOLIA_"]),
        .init(name: "Twilio",     category: .other,      dashboardURL: "https://console.twilio.com/",
              npmPackages: ["twilio"],
              envPrefixes: ["TWILIO_"]),
        .init(name: "Tinybird",   category: .analytics,  dashboardURL: "https://app.tinybird.co/",
              npmPackages: [], envPrefixes: ["TINYBIRD_"]),
    ]

    /// Detect providers in a project. Returns one Provider per matched signature.
    static func detect(in projectPath: String) -> [Provider] {
        let pkgDeps = readPackageDeps(at: "\(projectPath)/package.json")
        let envKeys = readEnvKeys(in: projectPath)

        var detected: [String: Provider] = [:]   // by name (dedupe across sources)
        let now = Date()

        for sig in signatures {
            // Try package matches first — they're more specific.
            if let pkg = sig.npmPackages.first(where: { pkgDeps.contains($0) }) {
                detected[sig.name] = Provider(
                    id: UUID().uuidString,
                    name: sig.name,
                    category: sig.category,
                    detectedFrom: .packageJSON(name: pkg),
                    dashboardURL: sig.dashboardURL.flatMap(URL.init(string:)),
                    monthlyEstimateUSD: nil,
                    notes: nil,
                    addedAt: now
                )
                continue
            }
            // Fall back to env prefix match.
            for prefix in sig.envPrefixes {
                if let key = envKeys.first(where: { $0.hasPrefix(prefix) }) {
                    detected[sig.name] = Provider(
                        id: UUID().uuidString,
                        name: sig.name,
                        category: sig.category,
                        detectedFrom: .envFile(key: key),
                        dashboardURL: sig.dashboardURL.flatMap(URL.init(string:)),
                        monthlyEstimateUSD: nil,
                        notes: nil,
                        addedAt: now
                    )
                    break
                }
            }
        }

        return Array(detected.values).sorted {
            if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
            return $0.name < $1.name
        }
    }

    private static func readPackageDeps(at path: String) -> Set<String> {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var keys: Set<String> = []
        if let d = json["dependencies"] as? [String: Any] { keys.formUnion(d.keys) }
        if let d = json["devDependencies"] as? [String: Any] { keys.formUnion(d.keys) }
        return keys
    }

    private static func readEnvKeys(in projectPath: String) -> Set<String> {
        var keys: Set<String> = []
        let candidates = [".env", ".env.local", ".env.example", ".env.development", ".env.production"]
        for f in candidates {
            let path = "\(projectPath)/\(f)"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if let eq = line.firstIndex(of: "=") {
                    let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { keys.insert(key) }
                }
            }
        }
        return keys
    }
}
