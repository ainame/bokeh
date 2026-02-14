import Foundation
import FltrLib

/// Benchmark for the Fltr matcher backend.
/// Dataset expanded to cover realistic file-path lengths and query patterns that
/// exercise different DP window sizes and selectivity levels.
public struct MatcherBenchmark {
    /// Benchmark dataset – mix of short and long paths, nested directories,
    /// camelCase names, and common file extensions.
    static let testData = [
        // Original set
        "src/components/Header.tsx",
        "src/components/Footer.tsx",
        "src/utils/string-helpers.ts",
        "src/pages/index.tsx",
        "src/pages/about.tsx",
        "tests/unit/components/Header.test.tsx",
        "tests/integration/api/users.test.ts",
        "README.md",
        "package.json",
        "tsconfig.json",
        "node_modules/react/index.js",
        "node_modules/@types/react/index.d.ts",
        // Deeper paths (stress wider DP windows)
        "src/components/navigation/sidebar/SidebarMenu.tsx",
        "src/components/navigation/sidebar/SidebarItem.tsx",
        "src/services/api/endpoints/getUserProfile.ts",
        "src/services/api/endpoints/updateSettings.ts",
        "src/hooks/useAuthContext.ts",
        "src/hooks/useLocalStorage.ts",
        "src/store/reducers/authReducer.ts",
        "src/store/reducers/settingsReducer.ts",
        "src/store/actions/fetchUserData.ts",
        "tests/unit/hooks/useAuthContext.test.ts",
        "tests/e2e/flows/loginAndNavigate.spec.ts",
        "tests/e2e/flows/signupAndVerify.spec.ts",
        // Short / no-match targets (test rejection speed)
        "a",
        "ab",
        "Makefile",
        "LICENSE",
        ".gitignore",
        ".eslintrc.json",
        "webpack.config.js",
        "babel.config.json",
        // Long paths (stress matrix size)
        "node_modules/@emotion/styled/dist/emotion-styled.cjs.prod.js",
        "node_modules/typescript/lib/typescript.d.ts",
        "node_modules/@testing-library/react/pure/dist/@testing-library/react.cjs.js",
        "dist/assets/chunks/vendor.a1b2c3d4.js",
        "dist/assets/css/main.e5f6g7h8.css",
        // camelCase heavy (stress bonus table)
        "src/components/DataTableColumnHeader.tsx",
        "src/utils/formatCurrencyValue.ts",
        "src/services/parseJSONResponse.ts",
    ]

    /// Queries at different selectivity levels:
    ///   high selectivity (rare match) → exercises rejection + narrow DP
    ///   low selectivity  (common)     → exercises full DP + scoring
    ///   multi-char       → wider windows
    static let queries = [
        // Original
        "src",
        "test",
        "Header",
        "tsx",
        "components",
        "react",
        // Added: longer patterns
        "sidebar",
        "reducer",
        "useAuth",
        "integration",
        // Added: patterns that won't match (rejection benchmark)
        "zzz",
        "xyz123",
        // Added: single char (maximum DP width, low selectivity)
        "a",
        "s",
    ]

    /// Run benchmark and return timing in milliseconds
    static func benchmark(
        name: String,
        iterations: Int = 10_000,
        matcher: (String, String) -> MatchResult?
    ) -> Double {
        // Warm-up: 100 iterations to let JIT / branch predictor settle
        for _ in 0..<100 {
            for query in queries {
                for text in testData {
                    _ = matcher(query, text)
                }
            }
        }

        let start = DispatchTime.now()

        for _ in 0..<iterations {
            for query in queries {
                for text in testData {
                    _ = matcher(query, text)
                }
            }
        }

        let end = DispatchTime.now()
        let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
        let totalMatches = iterations * queries.count * testData.count
        let matchesPerSecond = Double(totalMatches) / elapsed

        print("[\(name)]")
        print("  Total time: \(String(format: "%.3f", elapsed * 1000))ms")
        print("  Matches: \(totalMatches)")
        print("  Matches/sec: \(String(format: "%.0f", matchesPerSecond))")
        print("  Time per match: \(String(format: "%.3f", (elapsed * 1_000_000) / Double(totalMatches)))μs")

        return elapsed * 1000
    }

    public static func runComparison() {
        print("=== Matcher Performance Benchmark ===")
        print("  Dataset: \(testData.count) items × \(queries.count) queries\n")

        let backendMatcher = FuzzyMatcher(caseSensitive: false, scheme: .path)
        _ = benchmark(name: "Fltr backend (fuzzymatch)") { pattern, text in
            backendMatcher.match(pattern: pattern, text: text)
        }
    }
}
