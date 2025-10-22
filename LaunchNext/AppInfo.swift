import Foundation
import AppKit
import CoreServices

struct AppInfo: Identifiable, Equatable, Hashable {
    let name: String
    let icon: NSImage
    let url: URL

    // 使用应用路径作为稳定唯一标识
    var id: String { url.path }

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url.path)
    }

    // MARK: - 创建 AppInfo (🔧 MODIFICATO)
    static func from(url: URL, preferredName: String? = nil, customTitle: String? = nil) -> AppInfo {
        let fallbackName = normalizeCandidate(url.deletingPathExtension().lastPathComponent)
        let bundle = Bundle(url: url)
        let localizedName = localizedAppName(for: url,
                                             preferredName: preferredName,
                                             fallbackName: fallbackName,
                                             bundle: bundle)
        let englishName = englishAppName(preferredName: preferredName,
                                         fallbackName: fallbackName,
                                         bundle: bundle)

        let shouldUseLocalized = shouldUseLocalizedTitles()
        let chosenName = shouldUseLocalized ? localizedName : englishName
        
        //FIX: Caricamento icone più robusto
        let icon = loadAppIcon(for: url, bundle: bundle)

        if let override = customTitle.flatMap({ title -> String? in
            let normalized = normalizeCandidate(title)
            return normalized.isEmpty ? nil : normalized
        }) {
            return AppInfo(name: override, icon: icon, url: url)
        }

        return AppInfo(name: chosenName, icon: icon, url: url)
    }

    // MARK: - 获取本地化应用名
    private static func localizedAppName(for url: URL,
                                         preferredName: String?,
                                         fallbackName: String,
                                         bundle: Bundle?) -> String {
        var resolvedName: String? = nil

        func consider(_ rawValue: String?, source: String) {
            guard let rawValue = rawValue else {
                return
            }
            let normalized = normalizeCandidate(rawValue)
            if normalized.isEmpty {
                return
            }
            guard resolvedName == nil else { return }
            if normalized != fallbackName {
                resolvedName = normalized
            }
        }

        if let bundle {
            consider(bundlePreferredDisplayName(bundle), source: "BundlePreferredDisplayName")
        }

        return resolvedName ?? fallbackName
    }

    private static func englishAppName(preferredName: String?,
                                       fallbackName: String,
                                       bundle: Bundle?) -> String {
        var candidates: [String] = []

        if let bundle {
            let englishLocales = ["en", "en-US", "en-GB"]
            for locale in englishLocales {
                if let path = bundle.path(forResource: "InfoPlist",
                                           ofType: "strings",
                                           inDirectory: nil,
                                           forLocalization: locale),
                   let dict = NSDictionary(contentsOfFile: path) as? [String: String] {
                    for key in ["CFBundleDisplayName", "CFBundleName"] {
                        if let value = dict[key], !value.isEmpty {
                            candidates.append(value)
                        }
                    }
                }
            }

            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = bundle.infoDictionary?[key] as? String, !value.isEmpty {
                    candidates.append(value)
                }
            }
        }

        if let preferredName, !preferredName.isEmpty {
            candidates.append(preferredName)
        }

        for raw in candidates {
            let normalized = normalizeCandidate(raw)
            if !normalized.isEmpty {
                return normalized
            }
        }

        return fallbackName
    }

    private static func shouldUseLocalizedTitles() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "useLocalizedThirdPartyTitles") == nil {
            return true
        }
        return defaults.bool(forKey: "useLocalizedThirdPartyTitles")
    }

    private static func normalizeCandidate(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix(".app") {
            trimmed = String(trimmed.dropLast(4))
        }
        return trimmed
    }

    private static func bundlePreferredDisplayName(_ bundle: Bundle) -> String? {
        let preferredLocales = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: userPreferredLanguages())
        if let chosen = preferredLocales.first,
           let lprojPath = bundle.path(forResource: chosen, ofType: "lproj"),
           let localizedBundle = Bundle(path: lprojPath),
           let stringsPath = localizedBundle.path(forResource: "InfoPlist", ofType: "strings"),
           let dict = NSDictionary(contentsOfFile: stringsPath) as? [String: String] {
            if let displayName = dict["CFBundleDisplayName"], !displayName.isEmpty {
                return displayName
            }
            if let bundleName = dict["CFBundleName"], !bundleName.isEmpty {
                return bundleName
            }
        }

        if let localizedInfo = bundle.localizedInfoDictionary {
            if let displayName = localizedInfo["CFBundleDisplayName"] as? String, !displayName.isEmpty {
                return displayName
            }
            if let bundleName = localizedInfo["CFBundleName"] as? String, !bundleName.isEmpty {
                return bundleName
            }
        }

        return nil
    }

    private static func userPreferredLanguages() -> [String] {
        if let languages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String], !languages.isEmpty {
            return languages
        }
        return Locale.preferredLanguages
    }
    
    // MARK: - NUOVO: Caricamento icone robusto
    private static func loadAppIcon(for url: URL, bundle: Bundle?) -> NSImage {
        // Metodo 1: Prova con NSWorkspace
        let workspaceIcon = NSWorkspace.shared.icon(forFile: url.path)
        
        // Verifica se l'icona è valida (non quella generica)
        let isValidIcon = workspaceIcon.representations.count > 1 || 
                          workspaceIcon.size.width > 128
        
        if isValidIcon {
            return workspaceIcon
        }
        
        // Metodo 2: Carica direttamente dal bundle dell'app
        if let bundle = bundle {
            // Cerca il nome del file icona
            if let iconFileName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
                let iconName = iconFileName.replacingOccurrences(of: ".icns", with: "")
                
                // Prova a caricare l'icona dal Resources
                if let iconPath = bundle.path(forResource: iconName, ofType: "icns") {
                    if let icon = NSImage(contentsOfFile: iconPath), 
                       icon.isValid {
                        return icon
                    }
                }
                
                // Prova anche senza estensione
                if let iconPath = bundle.path(forResource: iconName, ofType: nil) {
                    if let icon = NSImage(contentsOfFile: iconPath),
                       icon.isValid {
                        return icon
                    }
                }
            }
            
            // Metodo 3: Cerca CFBundleIconName (per asset catalogs)
            if let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
               let iconPath = bundle.pathForImageResource(iconName) {
                if let icon = NSImage(contentsOfFile: iconPath),
                   icon.isValid {
                    return icon
                }
            }
            
            // Metodo 4: Cerca manualmente nella cartella Resources
            if let resourcesPath = bundle.resourcePath {
                let resourcesURL = URL(fileURLWithPath: resourcesPath)
                let icnsFiles = try? FileManager.default.contentsOfDirectory(
                    at: resourcesURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension.lowercased() == "icns" }
                
                // Prova il primo file .icns trovato
                if let firstIconFile = icnsFiles?.first,
                   let icon = NSImage(contentsOfFile: firstIconFile.path),
                   icon.isValid {
                    return icon
                }
            }
        }
        
        // Metodo 5: Ultimo tentativo - forza NSWorkspace con path risolto
        let resolvedURL = url.resolvingSymlinksInPath()
        let fallbackIcon = NSWorkspace.shared.icon(forFile: resolvedURL.path)
        
        return fallbackIcon
    }
}

// MARK: - NUOVA EXTENSION: Validazione icone
private extension NSImage {
    var isValid: Bool {
        return !representations.isEmpty && 
               size.width > 0 && 
               size.height > 0
    }
}
