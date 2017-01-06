//
//  AppDelegate.swift
//  Spotify Notifications
//
//  Created by Mihir Singh on 1/7/15.
//  Copyright (c) 2015 citruspi. All rights reserved.
//

import Cocoa
import ScriptingBridge

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSUserNotificationCenterDelegate {
    
    //Menu Bar
    var statusItem: NSStatusItem?
    @IBOutlet var statusMenu: NSMenu!
    
    @IBOutlet var openSpotifyMenuItem: NSMenuItem!
    @IBOutlet var openLastFMMenu: NSMenuItem!
    
    @IBOutlet var aboutPrefsController: AboutPreferencesController!

    var previousTrack: SpotifyTrack?
    var currentTrack: SpotifyTrack?
    
    var spotify: SpotifyApplication!
    
    lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        
        let session = URLSession(configuration: config)
        return session
    }()
    
    var albumArtTask: URLSessionDataTask?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        
        //Register default preferences values
        let defaultsPath = Bundle.main.path(forResource: "UserDefaults", ofType: "plist")
        let defaults = NSDictionary.init(contentsOfFile: defaultsPath!) as! [String : Any]
        UserDefaults.standard.register(defaults: defaults)
        
        spotify = SBApplication(bundleIdentifier: Constants.SpotifyBundleID) as! SpotifyApplication
        
        NSUserNotificationCenter.default.delegate = self
        
        //Observe Spotify player state changes
        let notificationName = Notification.Name(Constants.SpotifyNotificationName)
        DistributedNotificationCenter.default().addObserver(self,
                                                            selector: #selector(spotifyPlaybackStateChanged),
                                                            name: notificationName,
                                                            object: nil)
        
        updateStatusIcon()
        
        LaunchAtLogin.setAppIsLoginItem(UserDefaults.standard.bool(forKey: Constants.LaunchAtLoginKey))
        
        if spotify.running {
            let playerState = spotify.playerState
            
            if playerState == .playing || playerState == .paused {
                currentTrack = spotify.currentTrack
                setLastFMMenuEnabled(true)
            }
            
            if playerState == .playing {
                showCurrentTrackNotification(forceDelivery: true)
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        if albumArtTask != nil {
            albumArtTask?.cancel()
        }
        
        DistributedNotificationCenter.default().removeObserver(self)
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        //Allow opening preferences by re-opening the app
        //This allows accessing preferences even when the status item is hidden
        if !flag {
            aboutPrefsController.showPreferencesWindow(nil)
        }
        
        return true;
    }
    
    //MARK: - Spotify State
    
    func notPlaying() {
        openSpotifyMenuItem.title = "Open Spotify (Not Playing)"
        
        setLastFMMenuEnabled(false)
        
        NSUserNotificationCenter.default.removeAllDeliveredNotifications()
    }
    
    func spotifyPlaybackStateChanged(_ notification: NSNotification) {
        if notification.userInfo?["Player State"] as! String == "Stopped" {
            notPlaying()
            return //To stop us from checking accessing spotify (spotify.playerState below)..
            //..and then causing it to re-open
        }
        
        if spotify.playerState == .playing {
            openSpotifyMenuItem.title = "Open Spotify (Playing)"
            
            previousTrack = currentTrack
            currentTrack = spotify.currentTrack
            
            //If track has different album art to previous, and album art task ongoing
            if previousTrack != nil && previousTrack!.album! != currentTrack!.album! && albumArtTask != nil {
                albumArtTask?.cancel()
            }
            
            setLastFMMenuEnabled(true)
            
            showCurrentTrackNotification(forceDelivery: false)
            
        } else if UserDefaults.standard.bool(forKey: Constants.ShowOnlyCurrentSongKey)
            && (spotify.playerState == .paused || spotify.playerState == .stopped) {
            notPlaying()
        }
    }
    
    //MARK: - UI
    func setLastFMMenuEnabled(_ enabled: Bool) {
        openLastFMMenu.isEnabled = enabled
    }
    
    func updateStatusIcon() {
        let iconSelection = UserDefaults.standard.integer(forKey: Constants.IconSelectionKey)
        
        if iconSelection == 2 && statusItem != nil {
            statusItem = nil
            
        } else if iconSelection < 2 {
            if statusItem == nil {
                statusItem = NSStatusBar.system().statusItem(withLength: NSSquareStatusItemLength)
                statusItem!.menu = statusMenu
                statusItem!.highlightMode = true
            }
            
            let imageName = iconSelection == 0 ? "status_bar_colour" : "status_bar_black"
            
            if statusItem!.image?.name() != imageName {
                statusItem!.image = NSImage(named: imageName)
            }
            
            statusItem!.image?.isTemplate = (iconSelection == 1)
        }
    }
    
    @IBAction func openSpotify(_ sender: NSMenuItem) {
        spotify.activate()
    }
    
    @IBAction func openLastFM(_ sender: NSMenuItem) {
        
        if let track = currentTrack {
            //Artist - we always need at least this
            let urlText = NSMutableString(string: "http://last.fm/music/")
            
            if let artist = track.artist?.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) {
                urlText.appendFormat("%@/",artist);
            }
            if let album = track.album?.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed), sender.tag >= 1 {
                urlText.appendFormat("%@/", album)
            }
            
            if let trackName = track.name?.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed), sender.tag == 2 {
                urlText.appendFormat("%@/", trackName)
            }
            
            if let url = URL(string: urlText as String) {
                NSWorkspace.shared().open(url)
            }
        }
    }
    
    //MARK: - Notifications
    
    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }
    
    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        let actionType = notification.activationType
        
        if actionType == .contentsClicked {
            spotify.activate()
            
        } else if actionType == .actionButtonClicked && spotify.playerState == .playing {
            spotify.nextTrack!()
        }
    }
    
    func getAlbumArt(track: SpotifyTrack, completionHandler: @escaping (SpotifyTrack, NSImage?) -> ()) {
        if let url = track.artworkUrl {
            let urlHTTPS = url.replacingOccurrences(of: "http:", with: "https:")
            
            if let finalURL = URL(string: urlHTTPS) {
                albumArtTask = urlSession.dataTask(with: finalURL) { data, response, error in
                    if data != nil, let image = NSImage.init(data: data!), error == nil {
                        completionHandler(track, image)
                    } else {
                        completionHandler(track, nil)
                    }
                }
                albumArtTask?.resume()
            }
            
        } else {
            completionHandler(track, nil)
        }
    }
    
    func getFeaturedArtists(trackName: String) -> (Range<String.Index>, [String])? {
        
        if let startRange = trackName.range(of: "(feat. ") {
            
            let chars = trackName.characters
            
            if let endRange = trackName.range(of: ")", range: startRange.upperBound..<chars.endIndex) {
                
                let artists = trackName.substring(with: startRange.upperBound..<endRange.lowerBound)
                let artistsFormatted = NSMutableString(string: artists)
                
                for toReplace in [" & ", " and "] {
                    artistsFormatted.replaceOccurrences(of: toReplace, with: ", ", range: NSRange(location: 0, length: artistsFormatted.length))
                }
                
                let artistsRange = trackName.range(of: "(feat. "+artists+")")
                
                return (artistsRange!, artistsFormatted.components(separatedBy: ", "))
            }
        }
        
        return nil
    }
    
    func showCurrentTrackNotification(forceDelivery: Bool) {
        
        let notification = NSUserNotification()
        notification.title = "No Song Playing"
        
        let track = spotify.currentTrack!
        
        if UserDefaults.standard.bool(forKey: Constants.NotificationSoundKey) {
            notification.soundName = "Pop"
        }
        
        if (track.spotifyUrl?.hasPrefix("spotify:ad"))! {
            show(notification: notification, forceDelivery: forceDelivery)
            return
        }
        
        var trackName = track.name!
        
        var artists = track.artist!
        if let ftArtistsData = getFeaturedArtists(trackName: trackName) {
            //trackName = trackName.replacingCharacters(in: ftArtistsData.0, with: "")
            artists += ", " + ftArtistsData.1.joined(separator: ", ")
        }
        
        notification.title = trackName
        notification.subtitle = String(format: "%@ — %@", artists, track.album!)
        
        notification.hasActionButton = true
        notification.actionButtonTitle = "Skip"
        
        //Private API: Force showing buttons even if "Banner" alert style chosen by user
        notification.setValue(true, forKey: "_showsButtons")
        
        if UserDefaults.standard.bool(forKey: Constants.NotificationIncludeAlbumArtKey) {
            
            getAlbumArt(track: track, completionHandler: { (albumArtTrack, image) in
                
                //Check album art matches up to current song
                //(in case of network error/etc)
                if track.id!() == albumArtTrack.id!() && image != nil {
                    notification.contentImage = image
                    
                    //Private API: Show album art on the left side of the notification
                    //(where app icon normally is) like iTunes does
                    if notification.contentImage?.isValid ?? false {
                        notification.setValue(notification.contentImage, forKey: "_identityImage")
                        notification.contentImage = nil;
                    }
                }
                
                self.show(notification: notification, forceDelivery: forceDelivery)
            })
            
        } else {
            show(notification: notification, forceDelivery: forceDelivery)
        }
    }
    
    
    func show(notification: NSUserNotification, forceDelivery: Bool) {
        let frontmost = NSWorkspace.shared().frontmostApplication?.bundleIdentifier == Constants.SpotifyBundleID
        if frontmost && UserDefaults.standard.bool(forKey: Constants.DisableWhenSpotifyHasFocusKey) {
            return
        }
        
        var shouldDeliver = forceDelivery
        
        if !shouldDeliver {
            
            var isNewTrack = false
            if let current = currentTrack, let previous = previousTrack {
                isNewTrack = previous.id!() != current.id!()
            }
            
            //Deliver if notifications enabled AND (track is different OR same but play/pause notifs enabled)
            if UserDefaults.standard.bool(forKey: Constants.NotificationsKey)
                && (isNewTrack || UserDefaults.standard.bool(forKey: Constants.PlayPauseNotificationsKey)) {
                
                //If only showing notification for current song, remove all other notifications..
                if UserDefaults.standard.bool(forKey: Constants.ShowOnlyCurrentSongKey) {
                    NSUserNotificationCenter.default.removeAllDeliveredNotifications()
                }
                
                //..then make sure this one is delivered
                shouldDeliver = true;
            }
        }
        
        if shouldDeliver {
            albumArtTask = nil
            NSUserNotificationCenter.default.deliver(notification)
        }
    }
    
}
