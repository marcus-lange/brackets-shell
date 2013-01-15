/*
 * Copyright (c) 2012 Adobe Systems Incorporated. All rights reserved.
 *  
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"), 
 * to deal in the Software without restriction, including without limitation 
 * the rights to use, copy, modify, merge, publish, distribute, sublicense, 
 * and/or sell copies of the Software, and to permit persons to whom the 
 * Software is furnished to do so, subject to the following conditions:
 *  
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *  
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING 
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER 
 * DEALINGS IN THE SOFTWARE.
 * 
 */ 

#include "appshell_extensions_platform.h"
#include "appshell_extensions.h"
#include "native_menu_model.h"

#include <Cocoa/Cocoa.h>


@interface ChromeWindowsTerminatedObserver : NSObject
- (void)appTerminated:(NSNotification *)note;
- (void)timeoutTimer:(NSTimer*)timer;
@end

// App ID for either Chrome or Chrome Canary (commented out)
NSString *const appId = @"com.google.Chrome";
//NSString *const appId = @"com.google.Chrome.canary";

///////////////////////////////////////////////////////////////////////////////
// LiveBrowserMgrMac

class LiveBrowserMgrMac
{
public:
    static LiveBrowserMgrMac* GetInstance();
    static void Shutdown();

    bool IsChromeRunning();
    void CheckForChromeRunning();
    void CheckForChromeRunningTimeout();
    
    void CloseLiveBrowserKillTimers();
    void CloseLiveBrowserFireCallback(int valToSend);

    ChromeWindowsTerminatedObserver* GetTerminateObserver() { return m_chromeTerminateObserver; }
    CefRefPtr<CefProcessMessage> GetCloseCallback() { return m_closeLiveBrowserCallback; }
    
    void SetCloseTimeoutTimer(NSTimer* closeLiveBrowserTimeoutTimer)
            { m_closeLiveBrowserTimeoutTimer = closeLiveBrowserTimeoutTimer; }
    void SetTerminateObserver(ChromeWindowsTerminatedObserver* chromeTerminateObserver)
            { m_chromeTerminateObserver = chromeTerminateObserver; }
    void SetCloseCallback(CefRefPtr<CefProcessMessage> response)
            { m_closeLiveBrowserCallback = response; }
    void SetBrowser(CefRefPtr<CefBrowser> browser)
            { m_browser = browser; }
            

private:
    // private so this class cannot be instantiated externally
    LiveBrowserMgrMac();
    virtual ~LiveBrowserMgrMac();

    NSTimer*                            m_closeLiveBrowserTimeoutTimer;
    CefRefPtr<CefProcessMessage>        m_closeLiveBrowserCallback;
    CefRefPtr<CefBrowser>               m_browser;
    ChromeWindowsTerminatedObserver*    m_chromeTerminateObserver;
    
    static LiveBrowserMgrMac* s_instance;
};


LiveBrowserMgrMac::LiveBrowserMgrMac()
    : m_closeLiveBrowserTimeoutTimer(nil)
    , m_chromeTerminateObserver(nil)
{
}

LiveBrowserMgrMac::~LiveBrowserMgrMac()
{
    if (s_instance)
        s_instance->CloseLiveBrowserKillTimers();
}

LiveBrowserMgrMac* LiveBrowserMgrMac::GetInstance()
{
    if (!s_instance)
        s_instance = new LiveBrowserMgrMac();
    return s_instance;
}

void LiveBrowserMgrMac::Shutdown()
{
    delete s_instance;
    s_instance = NULL;
}

bool LiveBrowserMgrMac::IsChromeRunning()
{
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:appId];
    for (NSUInteger i = 0; i < apps.count; i++) {
        NSRunningApplication* curApp = [apps objectAtIndex:i];
        if( curApp && !curApp.terminated ) {
            return true;
        }
    }
    return false;
}

void LiveBrowserMgrMac::CloseLiveBrowserKillTimers()
{
    if (m_closeLiveBrowserTimeoutTimer) {
        [m_closeLiveBrowserTimeoutTimer invalidate];
        [m_closeLiveBrowserTimeoutTimer release];
        m_closeLiveBrowserTimeoutTimer = nil;
    }
    
    if (m_chromeTerminateObserver) {
        [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:m_chromeTerminateObserver];
        [m_chromeTerminateObserver release];
        m_chromeTerminateObserver = nil;
    }
}

void LiveBrowserMgrMac::CloseLiveBrowserFireCallback(int valToSend)
{
    CefRefPtr<CefListValue> responseArgs = m_closeLiveBrowserCallback->GetArgumentList();
    
    // kill the timers
    CloseLiveBrowserKillTimers();
    
    // Set common response args (callbackId and error)
    responseArgs->SetInt(1, valToSend);
    
    // Send response
    m_browser->SendProcessMessage(PID_RENDERER, m_closeLiveBrowserCallback);
    
    // Clear state
    m_closeLiveBrowserCallback = NULL;
    m_browser = NULL;
}

void LiveBrowserMgrMac::CheckForChromeRunning()
{
    if (IsChromeRunning())
        return;
    
    CloseLiveBrowserFireCallback(NO_ERROR);
}

void LiveBrowserMgrMac::CheckForChromeRunningTimeout()
{
    int retVal = (IsChromeRunning() ? ERR_UNKNOWN : NO_ERROR);
    
    //notify back to the app
    CloseLiveBrowserFireCallback(retVal);
}

LiveBrowserMgrMac* LiveBrowserMgrMac::s_instance = NULL;

// Forward declarations for functions defined later in this file
void NSArrayToCefList(NSArray* array, CefRefPtr<CefListValue>& list);
int32 ConvertNSErrorCode(NSError* error, bool isReading);

int32 OpenLiveBrowser(ExtensionString argURL, bool enableRemoteDebugging)
{
    // Parse the arguments
    NSString *urlString = [NSString stringWithUTF8String:argURL.c_str()];
    NSURL *url = [NSURL URLWithString:urlString];
    
    // Find instances of the Browser
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:appId];
    NSWorkspace * ws = [NSWorkspace sharedWorkspace];
    NSUInteger launchOptions = NSWorkspaceLaunchDefault | NSWorkspaceLaunchWithoutActivation;

    // Launch Browser
    if(apps.count == 0) {
        
        // Create the configuration dictionary for launching with custom parameters.
        NSArray *parameters = nil;
        if (enableRemoteDebugging) {
            parameters = [NSArray arrayWithObjects:
                           @"--remote-debugging-port=9222", 
                           @"--allow-file-access-from-files",
                           urlString,
                           nil];
        }
        else {
            parameters = [NSArray arrayWithObjects:
                           @"--allow-file-access-from-files",
                           urlString,
                           nil];
        }

        NSMutableDictionary* appConfig = [NSDictionary dictionaryWithObject:parameters forKey:NSWorkspaceLaunchConfigurationArguments];

        NSURL *appURL = [ws URLForApplicationWithBundleIdentifier:appId];
        if( !appURL ) {
            return ERR_NOT_FOUND; //Chrome not installed
        }
        NSError *error = nil;
        if( ![ws launchApplicationAtURL:appURL options:launchOptions configuration:appConfig error:&error] ) {
            return ERR_UNKNOWN;
        }
        return NO_ERROR;
    }
    
    // Tell the Browser to load the url
    [ws openURLs:[NSArray arrayWithObject:url] withAppBundleIdentifier:appId options:launchOptions additionalEventParamDescriptor:nil launchIdentifiers:nil];
    
    return NO_ERROR;
}

void CloseLiveBrowser(CefRefPtr<CefBrowser> browser, CefRefPtr<CefProcessMessage> response)
{
    LiveBrowserMgrMac* liveBrowserMgr = LiveBrowserMgrMac::GetInstance();
    
    if (liveBrowserMgr->GetCloseCallback() != NULL) {
        // We can only handle a single async callback at a time. If there is already one that hasn't fired then
        // we kill it now and get ready for the next.
        liveBrowserMgr->CloseLiveBrowserFireCallback(ERR_UNKNOWN);
    }
    
    liveBrowserMgr->SetBrowser(browser);
    liveBrowserMgr->SetCloseCallback(response);
    
    // Find instances of the Browser and terminate them
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:appId];
    
    if (apps.count == 0) {
        // No instances of Chrome found. Fire callback immediately.
        liveBrowserMgr->CloseLiveBrowserFireCallback(NO_ERROR);
        return;
    } else if (apps.count > 0 && !LiveBrowserMgrMac::GetInstance()->GetTerminateObserver()) {
        //register an observer to watch for the app terminations
        LiveBrowserMgrMac::GetInstance()->SetTerminateObserver([[ChromeWindowsTerminatedObserver alloc] init]);
        
        [[[NSWorkspace sharedWorkspace] notificationCenter]
                addObserver:LiveBrowserMgrMac::GetInstance()->GetTerminateObserver() 
                selector:@selector(appTerminated:) 
                name:NSWorkspaceDidTerminateApplicationNotification 
                object:nil
         ];
    }
    
    // Iterate over open browser intances and terminate
    for (NSUInteger i = 0; i < apps.count; i++) {
        NSRunningApplication* curApp = [apps objectAtIndex:i];
        if( curApp && !curApp.terminated ) {
            [curApp terminate];
        }
    }
    
    //start a timeout timer
    liveBrowserMgr->SetCloseTimeoutTimer([[NSTimer
                                         scheduledTimerWithTimeInterval:(3 * 60)
                                         target:LiveBrowserMgrMac::GetInstance()->GetTerminateObserver()
                                         selector:@selector(timeoutTimer:)
                                         userInfo:nil repeats:NO] retain]
                                         );
}

int32 OpenURLInDefaultBrowser(ExtensionString url)
{
    NSString* urlString = [NSString stringWithUTF8String:url.c_str()];
    
    if ([[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString: urlString]] == NO) {
        return ERR_UNKNOWN;
    }
    
    return NO_ERROR;
}

int32 ShowOpenDialog(bool allowMulitpleSelection,
                     bool chooseDirectory,
                     ExtensionString title,
                     ExtensionString initialDirectory,
                     ExtensionString fileTypes,
                     CefRefPtr<CefListValue>& selectedFiles)
{
    NSArray* allowedFileTypes = nil;
    BOOL canChooseDirectories = chooseDirectory;
    BOOL canChooseFiles = !canChooseDirectories;
    
    if (fileTypes != "")
    {
        // fileTypes is a Space-delimited string
        allowedFileTypes = 
        [[NSString stringWithUTF8String:fileTypes.c_str()] 
         componentsSeparatedByString:@" "];
    }
    
    // Initialize the dialog
    NSOpenPanel* openPanel = [NSOpenPanel openPanel];
    [openPanel setCanChooseFiles:canChooseFiles];
    [openPanel setCanChooseDirectories:canChooseDirectories];
    [openPanel setCanCreateDirectories:canChooseDirectories];
    [openPanel setAllowsMultipleSelection:allowMulitpleSelection];
    [openPanel setShowsHiddenFiles: YES];
    [openPanel setTitle: [NSString stringWithUTF8String:title.c_str()]];
    
    if (initialDirectory != "")
        [openPanel setDirectoryURL:[NSURL URLWithString:[NSString stringWithUTF8String:initialDirectory.c_str()]]];
    
    [openPanel setAllowedFileTypes:allowedFileTypes];
    
    [openPanel beginSheetModalForWindow:[NSApp mainWindow] completionHandler:nil];
    if ([openPanel runModal] == NSOKButton)
    {
        NSArray* urls = [openPanel URLs];
        for (NSUInteger i = 0; i < [urls count]; i++) {
            selectedFiles->SetString(i, [[[urls objectAtIndex:i] path] UTF8String]);
        }
    }
    [NSApp endSheet:openPanel];
    
    return NO_ERROR;
}

int32 ReadDir(ExtensionString path, CefRefPtr<CefListValue>& directoryContents)
{
    NSString* pathStr = [NSString stringWithUTF8String:path.c_str()];
    NSError* error = nil;
    
    if ([pathStr length] == 0) {
        return ERR_INVALID_PARAMS;
    }

    NSArray* contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:pathStr error:&error];
    
    if (contents != nil)
    {
        NSArrayToCefList(contents, directoryContents);
        return NO_ERROR; 
    }
    
    return ConvertNSErrorCode(error, true);
}

int32 MakeDir(ExtensionString path, int32 mode)
{
    NSError* error = nil;
    NSString* pathStr = [NSString stringWithUTF8String:path.c_str()];
  
    // TODO (issue #1759): honor mode
    [[NSFileManager defaultManager] createDirectoryAtPath:pathStr withIntermediateDirectories:TRUE attributes:nil error:&error];
  
    return ConvertNSErrorCode(error, false);
}

int32 Rename(ExtensionString oldName, ExtensionString newName)
{
    NSError* error = nil;
    NSString* oldPathStr = [NSString stringWithUTF8String:oldName.c_str()];
    NSString* newPathStr = [NSString stringWithUTF8String:newName.c_str()];
  
    // Check to make sure newName doesn't already exist. On OS 10.7 and later, moveItemAtPath
    // returns a nice "NSFileWriteFileExists" error in this case, but 10.6 returns a generic
    // "can't write" error.
    if ([[NSFileManager defaultManager] fileExistsAtPath:newPathStr]) {
        return ERR_FILE_EXISTS;
    }
  
    [[NSFileManager defaultManager] moveItemAtPath:oldPathStr toPath:newPathStr error:&error];
  
    return ConvertNSErrorCode(error, false);
}

int32 GetFileModificationTime(ExtensionString filename, uint32& modtime, bool& isDir)
{
    NSString* path = [NSString stringWithUTF8String:filename.c_str()];
    BOOL isDirectory;
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory]) {
        isDir = isDirectory;
    } else {
        return ERR_NOT_FOUND;
    }
    
    NSError* error = nil;
    NSDictionary* fileAttribs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&error];
    NSDate *modDate = [fileAttribs valueForKey:NSFileModificationDate];
    modtime = [modDate timeIntervalSince1970];
    
    return ConvertNSErrorCode(error, true);
}

int32 ReadFile(ExtensionString filename, ExtensionString encoding, std::string& contents)
{
    NSString* path = [NSString stringWithUTF8String:filename.c_str()];
    
    NSStringEncoding enc;
    NSError* error = nil;
    
    if (encoding == "utf8")
        enc = NSUTF8StringEncoding;
    else
        return ERR_UNSUPPORTED_ENCODING; 
    
    NSString* fileContents = [NSString stringWithContentsOfFile:path encoding:enc error:&error];
    
    if (fileContents) 
    {
        contents = [fileContents UTF8String];
        return NO_ERROR;
    }
    
    return ConvertNSErrorCode(error, true);
}

int32 WriteFile(ExtensionString filename, std::string contents, ExtensionString encoding)
{
    NSString* path = [NSString stringWithUTF8String:filename.c_str()];
    NSString* contentsStr = [NSString stringWithUTF8String:contents.c_str()];
    NSStringEncoding enc;
    NSError* error = nil;
    
    if (encoding == "utf8")
        enc = NSUTF8StringEncoding;
    else
        return ERR_UNSUPPORTED_ENCODING;
    
    const NSData* encodedContents = [contentsStr dataUsingEncoding:enc];
    NSUInteger len = [encodedContents length];
    NSOutputStream* oStream = [NSOutputStream outputStreamToFileAtPath:path append:NO];
    
    [oStream open];
    NSInteger res = [oStream write:(const uint8_t*)[encodedContents bytes] maxLength:len];
    [oStream close];
    
    if (res == -1) {
        error = [oStream streamError];
    }  
    
    return ConvertNSErrorCode(error, false);
}

int32 SetPosixPermissions(ExtensionString filename, int32 mode)
{
    NSError* error = nil;
    
    NSString* path = [NSString stringWithUTF8String:filename.c_str()];
    NSDictionary* attrs = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:mode] forKey:NSFilePosixPermissions];
    
    if ([[NSFileManager defaultManager] setAttributes:attrs ofItemAtPath:path error:&error])
        return NO_ERROR;
    
    return ConvertNSErrorCode(error, false);
}

int32 DeleteFileOrDirectory(ExtensionString filename)
{
    NSError* error = nil;
    
    NSString* path = [NSString stringWithUTF8String:filename.c_str()];
    BOOL isDirectory;
    
    // Contrary to the name of this function, we don't actually delete directories
    if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory]) {
        if (isDirectory) {
            return ERR_NOT_FILE;
        }
    } else {
        return ERR_NOT_FOUND;
    }    
    
    if ([[NSFileManager defaultManager] removeItemAtPath:path error:&error])
        return NO_ERROR;
    
    return ConvertNSErrorCode(error, false);
}

void NSArrayToCefList(NSArray* array, CefRefPtr<CefListValue>& list)
{
    for (NSUInteger i = 0; i < [array count]; i++) {
        list->SetString(i, [[[array objectAtIndex:i] precomposedStringWithCanonicalMapping] UTF8String]);
    }
}

int32 ConvertNSErrorCode(NSError* error, bool isReading)
{
    if (!error)
        return NO_ERROR;
    
    if( [[error domain] isEqualToString: NSPOSIXErrorDomain] )
    {
        switch ([error code]) 
        {
            case ENOENT:
                return ERR_NOT_FOUND;
                break;
            case EPERM:
            case EACCES:
                return (isReading ? ERR_CANT_READ : ERR_CANT_WRITE);
                break;
            case EROFS:
                return ERR_CANT_WRITE;
                break;
            case ENOSPC:
                return ERR_OUT_OF_SPACE;
                break;
        }
        
    }
    
    
    switch ([error code]) 
    {
        case NSFileNoSuchFileError:
        case NSFileReadNoSuchFileError:
            return ERR_NOT_FOUND;
            break;
        case NSFileReadNoPermissionError:
            return ERR_CANT_READ;
            break;
        case NSFileReadInapplicableStringEncodingError:
            return ERR_UNSUPPORTED_ENCODING;
            break;
        case NSFileWriteNoPermissionError:
            return ERR_CANT_WRITE;
            break;
        case NSFileWriteOutOfSpaceError:
            return ERR_OUT_OF_SPACE;
            break;
        case NSFileWriteFileExistsError:
            return ERR_FILE_EXISTS;
            break;
    }
    
    // Unknown error
    return ERR_UNKNOWN;
}


void OnBeforeShutdown()
{
    LiveBrowserMgrMac::Shutdown();
}

void CloseWindow(CefRefPtr<CefBrowser> browser)
{
  NSWindow* window = [browser->GetHost()->GetWindowHandle() window];
  
  // Tell the window delegate it's really time to close
  [[window delegate] performSelector:@selector(setIsReallyClosing)];
  browser->GetHost()->CloseBrowser();
}

void BringBrowserWindowToFront(CefRefPtr<CefBrowser> browser)
{
  NSWindow* window = [browser->GetHost()->GetWindowHandle() window];
  [window makeKeyAndOrderFront:nil];
}

@implementation ChromeWindowsTerminatedObserver

- (void) appTerminated:(NSNotification *)note
{
    LiveBrowserMgrMac::GetInstance()->CheckForChromeRunning();
}

- (void) timeoutTimer:(NSTimer*)timer
{
    LiveBrowserMgrMac::GetInstance()->CheckForChromeRunningTimeout();
}

@end

int32 ShowFolderInOSWindow(ExtensionString pathname)
{
    NSString* scriptString = [NSString stringWithFormat: @"activate application \"Finder\"\n tell application \"Finder\" to open posix file \"%s\"", pathname.c_str()];
    NSAppleScript* script = [[NSAppleScript alloc] initWithSource: scriptString];
    NSDictionary* errorDict = nil;
    [script executeAndReturnError: &errorDict];
    [script release];
    return NO_ERROR;
}


// Return index where menu or menu item should be placed.
// -1 indicates append.
NSInteger getMenuPosition(CefRefPtr<CefBrowser> browser, const ExtensionString& position, const ExtensionString& relativeId)
{
    NSInteger positionIdx = -1;
    if (position.size() == 0)
    {
        return positionIdx;
    }
    if ((position == "before" || position == "after") && relativeId.size() > 0) {
        int32 relativeTag = NativeMenuModel::getInstance(getMenuParent(browser)).getTag(relativeId);

        if (relativeTag != kTagNotFound) {
            NSMenuItem* item = (NSMenuItem*)NativeMenuModel::getInstance(getMenuParent(browser)).getOsItem(relativeTag);
            NSMenu* parentMenu = NULL;
            if (item != NULL) {
                parentMenu = [item menu];
            } else {
                parentMenu = [NSApp mainMenu];
            }
            positionIdx = [parentMenu indexOfItemWithTag:relativeTag];
            if (positionIdx >= 0 && position == "after") {
                positionIdx += 1;
            }
        }
    } else if (position == "first") {
        positionIdx = 0;
    }

    return positionIdx;
}

int32 AddMenu(CefRefPtr<CefBrowser> browser, ExtensionString itemTitle, ExtensionString command, ExtensionString position, ExtensionString relativeId) {

    NSString* itemTitleStr = [[NSString alloc] initWithUTF8String:itemTitle.c_str()];
    NSMenuItem *testItem = nil;
    int32 tag = NativeMenuModel::getInstance(getMenuParent(browser)).getTag(command);
    if (tag == kTagNotFound) {
        tag = NativeMenuModel::getInstance(getMenuParent(browser)).getOrCreateTag(command);
    } else {
        // menu already there
        return NO_ERROR;
    }
    NSInteger menuIdx = [[NSApp mainMenu] indexOfItemWithTag:tag];
    if (menuIdx >= 0) {
        // if we didn't find the tag, we shouldn't already have an item with this tag
        return ERR_UNKNOWN;
    } else {
        testItem = [[[NSMenuItem alloc] initWithTitle:itemTitleStr action:nil keyEquivalent:@""] autorelease];
        [testItem setTag:tag];
        NativeMenuModel::getInstance(getMenuParent(browser)).setOsItem(tag, (void*)testItem);
    }
    NSMenu *subMenu = [testItem submenu];
    if (subMenu == nil) {
        subMenu = [[[NSMenu alloc] initWithTitle:itemTitleStr] autorelease];
        [testItem setSubmenu:subMenu];
    }
   
    // Positioning hack. If position and relativeId are both "", put the menu
    // before the window menu *except* if it is the Help menu.
    if (position.size() == 0 && relativeId.size() == 0 && command != "help-menu") {
        position = "before";
        relativeId = "window";
    }
    
    NSInteger positionIdx = getMenuPosition(browser, position, relativeId);
    if (positionIdx > -1) {
        [[NSApp mainMenu] insertItem:testItem atIndex:positionIdx];
    } else {
        [[NSApp mainMenu] addItem:testItem];
    }
   
    return NO_ERROR;
}

// Looks at modifiers and special keys in "key",
// removes then and returns an unsigned int mask
// that can be used by setKeyEquivalentModifierMask
NSUInteger processKeyString(ExtensionString& key)
{
    // Bail early if empty string is passed
    if (key == "") {
        return 0;
    }
    NSUInteger mask = 0;
    if (appshell_extensions::fixupKey(key, "Cmd-", "")) {
        mask |= NSCommandKeyMask;
    }
    if (appshell_extensions::fixupKey(key, "Ctrl-", "")) {
        mask |= NSControlKeyMask;
    }
    if (appshell_extensions::fixupKey(key, "Shift-", "")) {
        mask |= NSShiftKeyMask;
    }
    if (appshell_extensions::fixupKey(key, "Alt-", "") ||
        appshell_extensions::fixupKey(key, "Opt-", "")) {
        mask |= NSAlternateKeyMask;
    }
    //replace special keys with ones expected by keyEquivalent
    const ExtensionString del = (ExtensionString() += NSDeleteCharacter);
    const ExtensionString backspace = (ExtensionString() += NSBackspaceCharacter);
    const ExtensionString tab = (ExtensionString() += NSTabCharacter);
    const ExtensionString enter = (ExtensionString() += NSEnterCharacter);
    
    appshell_extensions::fixupKey(key, "Delete", del);
    appshell_extensions::fixupKey(key, "Backspace", backspace);
    appshell_extensions::fixupKey(key, "Tab", tab);
    appshell_extensions::fixupKey(key, "Enter", enter);
    appshell_extensions::fixupKey(key, "Up", "↑");
    appshell_extensions::fixupKey(key, "Down", "↓");
    appshell_extensions::fixupKey(key, "Left", "←");
    appshell_extensions::fixupKey(key, "Right", "→");

    // from unicode display char to ascii hyphen
    appshell_extensions::fixupKey(key, "−", "-");

    return mask;
}

int32 AddMenuItem(CefRefPtr<CefBrowser> browser, ExtensionString parentCommand, ExtensionString itemTitle, ExtensionString command, ExtensionString key, ExtensionString position, ExtensionString relativeId) {
    NSString* itemTitleStr = [[NSString alloc] initWithUTF8String:itemTitle.c_str()];
    NSMenuItem *testItem = nil;
    int32 parentTag = NativeMenuModel::getInstance(getMenuParent(browser)).getTag(parentCommand);
    bool isSeparator = (itemTitle == "---");
    if (parentTag == kTagNotFound) {
        return NO_ERROR;
    }
    int32 tag = NativeMenuModel::getInstance(getMenuParent(browser)).getTag(command);
    if (tag == kTagNotFound) {
        tag = NativeMenuModel::getInstance(getMenuParent(browser)).getOrCreateTag(command);
    } else {
        return NO_ERROR;
    }

    NSInteger menuIdx;
    testItem = (NSMenuItem*)NativeMenuModel::getInstance(getMenuParent(browser)).getOsItem(parentTag);
    
    if (testItem != nil) {
        NSMenu* subMenu = nil;
        if (![testItem hasSubmenu]) {
            subMenu = [[[NSMenu alloc] initWithTitle:itemTitleStr] autorelease];
            [testItem setSubmenu:subMenu];
        }
        subMenu = [testItem submenu];
        if (subMenu != nil) {
            if (isSeparator) {
                menuIdx = -1;
            }
            else {
                menuIdx = [subMenu indexOfItemWithTag:tag];
            }
            
            if (menuIdx < 0) {
                NSMenuItem* newItem = nil;
                if (isSeparator) {
                    newItem = [NSMenuItem separatorItem];
                }
                else {
                    NSUInteger mask = processKeyString(key);
                    NSString* keyStr = [[NSString alloc] initWithUTF8String:key.c_str()];
                    keyStr = [keyStr lowercaseString];
                    newItem = [NSMenuItem alloc];
                    [newItem setTitle:itemTitleStr];
                    [newItem setAction:NSSelectorFromString(@"handleMenuAction:")];
                    [newItem setKeyEquivalent:keyStr];
                    [newItem setKeyEquivalentModifierMask:mask];
                    [newItem setTag:tag];
                    NativeMenuModel::getInstance(getMenuParent(browser)).setOsItem(tag, (void*)newItem);
                }
                NSInteger positionIdx = getMenuPosition(browser, position, relativeId);
                if (positionIdx > -1) {
                    [subMenu insertItem:newItem atIndex:positionIdx];
                } else {
                    [subMenu addItem:newItem];
                }
            }
        }
    }

    return NO_ERROR;
}

int32 GetMenuItemState(CefRefPtr<CefBrowser> browser, ExtensionString commandId, bool& enabled, bool &checked, int& index)
{
    int32 tag = NativeMenuModel::getInstance(getMenuParent(browser)).getTag(commandId);
    if (tag == kTagNotFound) {
        return ERR_NOT_FOUND;
    }
    NSMenuItem* item = (NSMenuItem*)NativeMenuModel::getInstance(getMenuParent(browser)).getOsItem(tag);
    if (item == NULL) {
        return ERR_NOT_FOUND;
    }
    if ([item respondsToSelector:@selector(menu)]) {
        NSWindow* mainWindow = [NSApp mainWindow];
        //menu item's enabled status is dependent on the selector's return value.
        //[item enabled] will only be correct if we use manual menu enablement.
        enabled = [(NSObject*)[mainWindow delegate] performSelector:@selector(validateMenuItem:) withObject:item];
        checked = ([item state] == NSOnState);
        index = [[item menu] indexOfItemWithTag:tag];
    }
    return NO_ERROR;
}

int32 SetMenuTitle(CefRefPtr<CefBrowser> browser, ExtensionString command, ExtensionString itemTitle) {
    NSString* itemTitleStr = [[NSString alloc] initWithUTF8String:itemTitle.c_str()];
    int32 tag = NativeMenuModel::getInstance(getMenuParent(browser)).getTag(command);
    if (tag == kTagNotFound) {
        return ERR_NOT_FOUND;
    }

    NSMenuItem* menuItem = (NSMenuItem*)NativeMenuModel::getInstance(getMenuParent(browser)).getOsItem(tag);
    if (menuItem == NULL) {
        return ERR_NOT_FOUND;
    }
    [menuItem setTitle:itemTitleStr];
    
    return NO_ERROR;
}

int32 GetMenuTitle(CefRefPtr<CefBrowser> browser, ExtensionString commandId, ExtensionString& title)
{
    int32 tag = NativeMenuModel::getInstance(getMenuParent(browser)).getTag(commandId);
    if (tag == kTagNotFound) {
        return ERR_NOT_FOUND;
    }
    NSMenuItem* item = (NSMenuItem*)NativeMenuModel::getInstance(getMenuParent(browser)).getOsItem(tag);
    if (item == NULL) {
        return ERR_NOT_FOUND;
    }
    title = [[item title] UTF8String];
    
    return NO_ERROR;
}

//Remove menu item associated with commandId
int32 RemoveMenu(CefRefPtr<CefBrowser> browser, const ExtensionString& commandId)
{
    //works for menu and menu item
    return RemoveMenuItem(browser, commandId);
}

//Remove menu item associated with commandId
int32 RemoveMenuItem(CefRefPtr<CefBrowser> browser, const ExtensionString& commandId)
{
    int tag = NativeMenuModel::getInstance(getMenuParent(browser)).getTag(commandId);
    if (tag == kTagNotFound) {
        return ERR_NOT_FOUND;
    }
    NSMenuItem* item = (NSMenuItem*)NativeMenuModel::getInstance(getMenuParent(browser)).getOsItem(tag);
    if (item == NULL) {
        return ERR_NOT_FOUND;
    }
    
    NSMenu* parentMenu = NULL;
    if ([item respondsToSelector:@selector(menu)]) {
        parentMenu = [item menu];
        if (parentMenu == NULL) {
            return ERR_NOT_FOUND;
        }
        [parentMenu removeItem:item];
        NativeMenuModel::getInstance(getMenuParent(browser)).removeMenuItem(commandId);
    } else {
        return ERR_NOT_FOUND;
    }
    
    return NO_ERROR;
}

void HandleEditCommand(CefRefPtr<CefBrowser> browser, const ExtensionString& commandId) {
    SEL theSelector = nil;
    
    if (commandId == EDIT_UNDO) {
        theSelector = NSSelectorFromString(@"undo:");
    } else if (commandId == EDIT_REDO) {
        theSelector = NSSelectorFromString(@"redo:");
    } else if (commandId == EDIT_CUT) {
        theSelector = NSSelectorFromString(@"cut:");
    } else if (commandId == EDIT_COPY) {
        theSelector = NSSelectorFromString(@"copy:");
    } else if (commandId == EDIT_PASTE) {
        theSelector = NSSelectorFromString(@"paste:");
    } else if (commandId == EDIT_SELECT_ALL) {
        theSelector = NSSelectorFromString(@"selectAll:");
    }
    
    if (theSelector != nil) {
        [[NSApplication sharedApplication] sendAction:theSelector to:nil from:nil];
    }
}

