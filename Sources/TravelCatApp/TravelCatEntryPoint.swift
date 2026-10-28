import Darwin
import Dispatch
import Foundation
import SwiftUI

/// Decide before SwiftUI constructs the delegate (which owns credentials, diagnostics
/// and normal application startup). Rejected probe requests never fall through.
@main
@MainActor
enum TravelCatEntryPoint {
    static func main() {
        do {
            if try PackagedTravelAcceptance.isRequested(arguments: Array(CommandLine.arguments.dropFirst())) {
                Task {
                    do {
                        let result = try await PackagedTravelAcceptance.run()
                        let data = try JSONEncoder().encode(result)
                        print(String(decoding: data, as: UTF8.self))
                        exit(EXIT_SUCCESS)
                    } catch {
                        print(PackagedTravelAcceptance.failureJSON(error))
                        exit(EXIT_FAILURE)
                    }
                }
                dispatchMain()
            }
        } catch {
            print(PackagedTravelAcceptance.failureJSON(error))
            exit(64)
        }
        TravelCatApp.main()
    }
}
