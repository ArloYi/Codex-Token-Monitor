#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <errno.h>
#import <poll.h>

static const NSTimeInterval AppServerResponseTimeout = 10.0;

static NSString *FormatTokens(long long tokens) {
    double value = (double)tokens / 10000.0;
    if (value >= 1000) {
        return [NSString stringWithFormat:@"%.0f万", value];
    }
    if (value >= 100) {
        return [NSString stringWithFormat:@"%.1f万", value];
    }
    return [NSString stringWithFormat:@"%.2f万", value];
}

static NSString *FormatLifetimeTokens(long long tokens) {
    if (tokens >= 100000000) {
        return [NSString stringWithFormat:@"%.2f亿",
                                          (double)tokens / 100000000.0];
    }
    return FormatTokens(tokens);
}

static CGFloat AdaptiveFontSizeForText(NSString *text,
                                       CGFloat availableWidth) {
    CGFloat fontSize = 12.0;
    while (fontSize > 9.5) {
        NSFont *font =
            [NSFont monospacedDigitSystemFontOfSize:fontSize
                                             weight:NSFontWeightMedium];
        CGFloat textWidth =
            [text sizeWithAttributes:@{NSFontAttributeName: font}].width;
        if (textWidth <= availableWidth) break;
        fontSize -= 0.25;
    }
    return MAX(9.5, fontSize);
}

@interface ProjectSnapshot : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *path;
@property(nonatomic) long long weeklyProjectTokens;
@property(nonatomic) long long weeklyTotalTokens;
@end

@implementation ProjectSnapshot
@end

@interface QuotaSnapshot : NSObject
@property(nonatomic) double usedPercent;
@property(nonatomic, strong, nullable) NSDate *resetsAt;
@property(nonatomic) NSInteger windowDurationMinutes;
@property(nonatomic) long long lifetimeTokens;
@property(nonatomic, readonly) double remainingPercent;
@end

@implementation QuotaSnapshot
- (double)remainingPercent {
    return MAX(0, 100 - self.usedPercent);
}
@end

@interface CodexDataSource : NSObject
- (nullable ProjectSnapshot *)loadProjectSince:(NSDate *)windowStart;
- (nullable QuotaSnapshot *)loadQuota;
- (nullable NSData *)readLineFrom:(NSFileHandle *)handle
                          timeout:(NSTimeInterval)timeout;
@end

static NSNumber *_Nullable TotalTokensFromRolloutEvent(id eventValue) {
    if (![eventValue isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *event = eventValue;

    id payloadValue = event[@"payload"];
    if (![payloadValue isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *payload = payloadValue;

    id infoValue = payload[@"info"];
    if (![infoValue isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *info = infoValue;

    id usageValue = info[@"total_token_usage"];
    if (![usageValue isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *usage = usageValue;

    id tokensValue = usage[@"total_tokens"];
    return [tokensValue isKindOfClass:[NSNumber class]]
        ? tokensValue
        : nil;
}

static NSDictionary *_Nullable SelectedLocalProject(
    NSDictionary *state
) {
    NSDictionary *localProjects = state[@"local-projects"];
    if (![localProjects isKindOfClass:[NSDictionary class]]) return nil;

    id selectedValue = state[@"selected-project"];
    NSDictionary *selected =
        [selectedValue isKindOfClass:[NSDictionary class]]
            ? selectedValue
            : nil;
    NSString *projectId =
        [selected[@"projectId"] isKindOfClass:[NSString class]]
            ? selected[@"projectId"]
            : nil;
    id selectedProjectValue =
        projectId.length > 0 ? localProjects[projectId] : nil;
    NSDictionary *selectedProject =
        [selectedProjectValue isKindOfClass:[NSDictionary class]]
            ? selectedProjectValue
            : nil;
    NSArray *selectedRoots =
        [selectedProject[@"rootPaths"] isKindOfClass:[NSArray class]]
            ? selectedProject[@"rootPaths"]
            : nil;
    NSString *selectedPath =
        [selectedRoots.firstObject isKindOfClass:[NSString class]]
            ? selectedRoots.firstObject
            : nil;
    if (selectedProject && selectedPath.length > 0) {
        return @{
            @"project": selectedProject,
            @"path": selectedPath
        };
    }

    id activeRootsValue = state[@"active-workspace-roots"];
    NSArray *activeRoots =
        [activeRootsValue isKindOfClass:[NSArray class]]
            ? activeRootsValue
            : nil;
    NSString *activePath =
        [activeRoots.firstObject isKindOfClass:[NSString class]]
            ? activeRoots.firstObject
            : nil;
    if (activePath.length == 0) return nil;

    NSString *standardizedActivePath =
        activePath.stringByStandardizingPath;
    for (id value in localProjects.allValues) {
        if (![value isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *candidate = value;
        NSArray *rootPaths = candidate[@"rootPaths"];
        if (![rootPaths isKindOfClass:[NSArray class]]) continue;
        for (id valuePath in rootPaths) {
            if (![valuePath isKindOfClass:[NSString class]]) continue;
            NSString *rootPath = valuePath;
            if ([rootPath.stringByStandardizingPath
                    isEqualToString:standardizedActivePath]) {
                return @{
                    @"project": candidate,
                    @"path": activePath
                };
            }
        }
    }
    return nil;
}

static BOOL PathBelongsToProject(
    NSString *candidatePath,
    NSString *projectPath
) {
    NSString *candidate =
        candidatePath.stringByStandardizingPath;
    NSString *project =
        projectPath.stringByStandardizingPath;
    if (candidate.length == 0 || project.length == 0) return NO;
    if ([candidate isEqualToString:project]) return YES;
    NSString *prefix =
        [project stringByAppendingString:@"/"];
    return [candidate hasPrefix:prefix];
}

static NSString *CompactThreadTitle(
    NSString *title,
    NSString *path
) {
    NSString *trimmed =
        [title stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trimmed hasPrefix:@"["]) {
        NSRange markdownEnd =
            [trimmed rangeOfString:@"]("];
        if (markdownEnd.location != NSNotFound &&
            markdownEnd.location > 1) {
            trimmed =
                [trimmed substringWithRange:
                    NSMakeRange(1, markdownEnd.location - 1)];
        }
    }
    if (trimmed.length == 0) {
        trimmed = path.lastPathComponent;
    }
    if (trimmed.length > 32) {
        trimmed = [[trimmed substringToIndex:31]
            stringByAppendingString:@"…"];
    }
    return trimmed;
}

static NSString *CollapsedThreadTitle(NSString *title) {
    if (![title isKindOfClass:[NSString class]]) return @"";
    NSRegularExpression *whitespace =
        [NSRegularExpression
            regularExpressionWithPattern:@"\\s+"
                                 options:0
                                   error:nil];
    NSString *collapsed =
        [whitespace
            stringByReplacingMatchesInString:title
                                     options:0
                                       range:NSMakeRange(0, title.length)
                                withTemplate:@" "];
    return [collapsed
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSArray<NSString *> *ThreadTitleVariants(NSString *storedTitle) {
    NSString *base = CollapsedThreadTitle(storedTitle);
    if (base.length == 0) return @[];

    NSMutableOrderedSet<NSString *> *variants =
        [NSMutableOrderedSet orderedSetWithObject:base];
    NSRegularExpression *markdownLink =
        [NSRegularExpression
            regularExpressionWithPattern:@"\\[([^\\]]+)\\]\\([^\\)]*\\)"
                                 options:0
                                   error:nil];
    NSString *visibleMarkdown =
        [markdownLink
            stringByReplacingMatchesInString:base
                                     options:0
                                       range:NSMakeRange(0, base.length)
                                withTemplate:@"$1"];
    visibleMarkdown = CollapsedThreadTitle(visibleMarkdown);
    if (visibleMarkdown.length > 0) {
        [variants addObject:visibleMarkdown];
    }

    NSRegularExpression *repositoryOwner =
        [NSRegularExpression
            regularExpressionWithPattern:
                @"[A-Za-z0-9_.-]+/([A-Za-z0-9_.-]+)"
                                 options:0
                                   error:nil];
    NSString *ownerless =
        [repositoryOwner
            stringByReplacingMatchesInString:visibleMarkdown
                                     options:0
                                       range:NSMakeRange(
                                           0,
                                           visibleMarkdown.length
                                       )
                                withTemplate:@"$1"];
    ownerless = CollapsedThreadTitle(ownerless);
    if (ownerless.length > 0) {
        [variants addObject:ownerless];
    }
    return variants.array;
}

static NSInteger ThreadTitleMatchScore(
    NSString *displayTitle,
    NSString *storedTitle
) {
    NSString *display =
        CollapsedThreadTitle(displayTitle).lowercaseString;
    if (display.length == 0) return 0;

    BOOL truncated =
        [display hasSuffix:@"…"] ||
        [display hasSuffix:@"..."];
    if ([display hasSuffix:@"…"]) {
        display = [display substringToIndex:display.length - 1];
    } else if ([display hasSuffix:@"..."]) {
        display = [display substringToIndex:display.length - 3];
    }
    display = CollapsedThreadTitle(display);
    if (display.length == 0) return 0;

    NSInteger bestScore = 0;
    for (NSString *candidateValue in
            ThreadTitleVariants(storedTitle)) {
        NSString *candidate = candidateValue.lowercaseString;
        if ([candidate isEqualToString:display]) {
            bestScore = MAX(
                bestScore,
                100000 + (NSInteger)display.length
            );
            continue;
        }

        NSUInteger shorterLength =
            MIN(display.length, candidate.length);
        if (shorterLength >= 6 &&
            ([candidate hasPrefix:display] ||
             [display hasPrefix:candidate])) {
            bestScore = MAX(
                bestScore,
                (truncated ? 90000 : 80000) +
                    (NSInteger)shorterLength
            );
        }
        if (display.length >= 6 &&
            [candidate containsString:display]) {
            bestScore = MAX(
                bestScore,
                70000 + (NSInteger)display.length
            );
        }

        NSUInteger commonPrefix = 0;
        while (commonPrefix < shorterLength &&
               [display characterAtIndex:commonPrefix] ==
                   [candidate characterAtIndex:commonPrefix]) {
            commonPrefix++;
        }
        NSUInteger requiredPrefix =
            MIN((NSUInteger)12, MAX((NSUInteger)6,
                display.length / 2));
        if (commonPrefix >= requiredPrefix) {
            bestScore = MAX(
                bestScore,
                1000 + (NSInteger)commonPrefix
            );
        }
    }
    return bestScore;
}

static id _Nullable AXCopiedAttribute(
    AXUIElementRef element,
    CFStringRef attribute
) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) != kAXErrorSuccess ||
        value == NULL) {
        return nil;
    }
    return CFBridgingRelease(value);
}

static NSString *_Nullable AXStringAttribute(
    AXUIElementRef element,
    CFStringRef attribute
) {
    id value = AXCopiedAttribute(element, attribute);
    return [value isKindOfClass:[NSString class]]
        ? value
        : nil;
}

static NSArray *_Nullable AXChildren(AXUIElementRef element) {
    id value = AXCopiedAttribute(element, kAXChildrenAttribute);
    return [value isKindOfClass:[NSArray class]]
        ? value
        : nil;
}

static NSString *_Nullable FirstAXStaticText(
    AXUIElementRef element,
    NSUInteger depth
) {
    if (depth > 5) return nil;
    NSString *role =
        AXStringAttribute(element, kAXRoleAttribute);
    if ([role isEqualToString:
            (__bridge NSString *)kAXStaticTextRole]) {
        NSString *value =
            AXStringAttribute(element, kAXValueAttribute);
        if (value.length > 0) return CollapsedThreadTitle(value);
    }
    for (id child in AXChildren(element)) {
        NSString *value =
            FirstAXStaticText(
                (__bridge AXUIElementRef)child,
                depth + 1
            );
        if (value.length > 0) return value;
    }
    return nil;
}

static NSString *_Nullable FindCurrentTaskTitleInAXTree(
    AXUIElementRef element,
    NSUInteger depth,
    NSMutableSet<NSNumber *> *visited
) {
    if (depth > 32 || visited.count > 3000) return nil;
    NSNumber *identity = @(CFHash(element));
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    NSArray *children = AXChildren(element);
    BOOL hasTaskActionsMenu = NO;
    for (id child in children) {
        AXUIElementRef childElement =
            (__bridge AXUIElementRef)child;
        NSString *role =
            AXStringAttribute(childElement, kAXRoleAttribute);
        if (![role isEqualToString:
                (__bridge NSString *)kAXPopUpButtonRole]) {
            continue;
        }
        NSString *description =
            AXStringAttribute(
                childElement,
                kAXDescriptionAttribute
            ).lowercaseString;
        if ([description containsString:@"任务操作"] ||
            [description containsString:@"task actions"] ||
            [description containsString:@"thread actions"]) {
            hasTaskActionsMenu = YES;
            break;
        }
    }
    if (hasTaskActionsMenu) {
        for (id child in children) {
            AXUIElementRef childElement =
                (__bridge AXUIElementRef)child;
            NSString *role =
                AXStringAttribute(
                    childElement,
                    kAXRoleAttribute
                );
            if (![role isEqualToString:
                    (__bridge NSString *)kAXGroupRole]) {
                continue;
            }
            NSString *title =
                FirstAXStaticText(childElement, 0);
            if (title.length > 0) return title;
        }
    }

    for (id child in children.reverseObjectEnumerator) {
        NSString *title =
            FindCurrentTaskTitleInAXTree(
                (__bridge AXUIElementRef)child,
                depth + 1,
                visited
            );
        if (title.length > 0) return title;
    }
    return nil;
}

static NSDictionary *_Nullable ProjectSelectionForActiveThread(
    NSDictionary *state,
    NSDictionary *_Nullable activeThread
) {
    NSString *activePath =
        [activeThread[@"path"] isKindOfClass:[NSString class]]
            ? activeThread[@"path"]
            : nil;
    if (activePath.length == 0) {
        return SelectedLocalProject(state);
    }

    NSDictionary *localProjects = state[@"local-projects"];
    NSDictionary *bestProject = nil;
    NSString *bestRoot = nil;
    if ([localProjects isKindOfClass:[NSDictionary class]]) {
        for (id value in localProjects.allValues) {
            if (![value isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *candidate = value;
            NSArray *rootPaths = candidate[@"rootPaths"];
            if (![rootPaths isKindOfClass:[NSArray class]]) continue;
            for (id rootValue in rootPaths) {
                if (![rootValue isKindOfClass:[NSString class]]) continue;
                NSString *root = rootValue;
                if (PathBelongsToProject(activePath, root) &&
                    root.length > bestRoot.length) {
                    bestProject = candidate;
                    bestRoot = root;
                }
            }
        }
    }
    if (bestProject && bestRoot.length > 0) {
        return @{
            @"project": bestProject,
            @"path": bestRoot
        };
    }

    NSString *title =
        [activeThread[@"title"] isKindOfClass:[NSString class]]
            ? activeThread[@"title"]
            : nil;
    NSString *name = CompactThreadTitle(title, activePath);
    return @{
        @"project": @{@"name": name ?: activePath.lastPathComponent},
        @"path": activePath
    };
}

@implementation CodexDataSource

- (NSURL *)codexHome {
    return [[[NSFileManager defaultManager] homeDirectoryForCurrentUser]
        URLByAppendingPathComponent:@".codex"];
}

- (nullable ProjectSnapshot *)loadProjectSince:(NSDate *)windowStart {
    NSURL *stateURL = [[self codexHome]
        URLByAppendingPathComponent:@".codex-global-state.json"];
    NSData *data = [NSData dataWithContentsOfURL:stateURL];
    if (!data) return nil;

    NSDictionary *state =
        [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![state isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *selection =
        ProjectSelectionForActiveThread(
            state,
            [self activeThreadFromDatabase]
        );
    NSDictionary *project = selection[@"project"];
    NSString *path = selection[@"path"];
    NSString *name =
        [project[@"name"] isKindOfClass:[NSString class]]
            ? project[@"name"]
            : path.lastPathComponent;
    if (path.length == 0 || name.length == 0) return nil;

    NSDictionary *usage =
        [self queryWeeklyUsageSince:windowStart projectPath:path];
    ProjectSnapshot *snapshot = [ProjectSnapshot new];
    snapshot.name = name;
    snapshot.path = path;
    snapshot.weeklyProjectTokens = [usage[@"project"] longLongValue];
    snapshot.weeklyTotalTokens = [usage[@"total"] longLongValue];
    return snapshot;
}

- (nullable NSDictionary *)activeThreadFromDatabase {
    NSURL *databaseURL =
        [[self codexHome] URLByAppendingPathComponent:@"state_5.sqlite"];
    if (![[NSFileManager defaultManager]
            fileExistsAtPath:databaseURL.path]) {
        return nil;
    }

    NSString *displayTitle =
        [self currentCodexTaskTitleFromAccessibility];
    if (displayTitle.length > 0) {
        NSDictionary<NSString *, NSString *> *sessionTitles =
            [self sessionTitlesByThreadID];
        NSString *candidateQuery =
            @"SELECT id, cwd, "
             "replace(replace(replace(title, char(9), ' '), "
             "char(10), ' '), char(13), ' ') "
             "FROM threads "
             "WHERE archived = 0 AND ("
             "thread_source = 'user' OR ("
             "COALESCE(thread_source, '') = '' AND source = 'vscode'"
             ")) "
             "ORDER BY MAX("
             "COALESCE(updated_at_ms, updated_at * 1000), "
             "COALESCE(recency_at_ms, recency_at * 1000)"
             ") DESC LIMIT 500;";
        NSString *candidateRows =
            [self runSQLiteQuery:candidateQuery
                     databaseURL:databaseURL];
        __block NSDictionary *bestMatch = nil;
        __block NSInteger bestScore = 0;
        [candidateRows
            enumerateLinesUsingBlock:
                ^(NSString *line, BOOL *stop) {
            NSArray<NSString *> *fields =
                [line componentsSeparatedByString:@"\t"];
            if (fields.count < 3 || fields[1].length == 0) {
                return;
            }
            NSString *indexedTitle = sessionTitles[fields[0]];
            NSInteger score = MAX(
                ThreadTitleMatchScore(
                    displayTitle,
                    fields[2]
                ),
                ThreadTitleMatchScore(
                    displayTitle,
                    indexedTitle
                )
            );
            if (score > bestScore) {
                bestScore = score;
                bestMatch = @{
                    @"id": fields[0],
                    @"path": fields[1],
                    @"title": displayTitle
                };
            }
        }];
        if (bestMatch && bestScore >= 1006) {
            return bestMatch;
        }
    }

    NSString *query =
        @"SELECT id, cwd, "
         "replace(replace(replace(title, char(9), ' '), "
         "char(10), ' '), char(13), ' ') "
         "FROM threads "
         "WHERE archived = 0 AND ("
         "thread_source = 'user' OR ("
         "COALESCE(thread_source, '') = '' AND source = 'vscode'"
         ")) "
         "ORDER BY MAX("
         "COALESCE(updated_at_ms, updated_at * 1000), "
         "COALESCE(recency_at_ms, recency_at * 1000)"
         ") DESC LIMIT 1;";
    NSString *row =
        [self runSQLiteQuery:query databaseURL:databaseURL];
    row = [row stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *fields =
        [row componentsSeparatedByString:@"\t"];
    if (fields.count < 3 || fields[1].length == 0) return nil;
    return @{
        @"id": fields[0],
        @"path": fields[1],
        @"title": fields[2]
    };
}

- (NSString *)runSQLiteQuery:(NSString *)query
                 databaseURL:(NSURL *)databaseURL {
    NSTask *task = [NSTask new];
    NSPipe *output = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/sqlite3"];
    task.arguments =
        @[@"-separator", @"\t", databaseURL.path, query];
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return @"";
    [task waitUntilExit];

    NSData *data =
        [output.fileHandleForReading readDataToEndOfFile];
    NSString *row = [[NSString alloc]
        initWithData:data
        encoding:NSUTF8StringEncoding];
    return row ?: @"";
}

- (NSDictionary<NSString *, NSString *> *)sessionTitlesByThreadID {
    NSURL *indexURL =
        [[self codexHome]
            URLByAppendingPathComponent:@"session_index.jsonl"];
    NSData *data = [NSData dataWithContentsOfURL:indexURL];
    if (!data) return @{};
    NSString *rows = [[NSString alloc]
        initWithData:data
        encoding:NSUTF8StringEncoding];
    NSMutableDictionary<NSString *, NSString *> *titles =
        [NSMutableDictionary dictionary];
    [rows enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSData *lineData =
            [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *entry =
            [NSJSONSerialization
                JSONObjectWithData:lineData
                           options:0
                             error:nil];
        if (![entry isKindOfClass:[NSDictionary class]]) return;
        NSString *threadID =
            [entry[@"id"] isKindOfClass:[NSString class]]
                ? entry[@"id"]
                : nil;
        NSString *threadName =
            [entry[@"thread_name"] isKindOfClass:[NSString class]]
                ? entry[@"thread_name"]
                : nil;
        if (threadID.length > 0 && threadName.length > 0) {
            titles[threadID] = threadName;
        }
    }];
    return titles;
}

- (nullable NSString *)currentCodexTaskTitleFromAccessibility {
    if (!AXIsProcessTrusted()) return nil;

    NSArray<NSRunningApplication *> *applications =
        [NSRunningApplication
            runningApplicationsWithBundleIdentifier:
                @"com.openai.codex"];
    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        for (NSRunningApplication *application in applications) {
            if (application.terminated) continue;
            AXUIElementRef appElement =
                AXUIElementCreateApplication(
                    application.processIdentifier
                );
            AXUIElementSetMessagingTimeout(appElement, 1.0);
            NSArray *windows =
                AXCopiedAttribute(appElement, kAXWindowsAttribute);
            for (id window in windows) {
                NSMutableSet<NSNumber *> *visited =
                    [NSMutableSet set];
                NSString *title =
                    FindCurrentTaskTitleInAXTree(
                        (__bridge AXUIElementRef)window,
                        0,
                        visited
                    );
                if (title.length > 0) {
                    CFRelease(appElement);
                    return title;
                }
            }
            CFRelease(appElement);
        }
        if (attempt == 0) usleep(300000);
    }
    return nil;
}

- (NSDictionary *)queryWeeklyUsageSince:(NSDate *)windowStart
                            projectPath:(NSString *)projectPath {
    NSURL *databaseURL =
        [[self codexHome] URLByAppendingPathComponent:@"state_5.sqlite"];
    if (![[NSFileManager defaultManager]
            fileExistsAtPath:databaseURL.path]) {
        return @{@"project": @0, @"total": @0};
    }

    long long startEpoch =
        (long long)floor(windowStart.timeIntervalSince1970);
    NSString *query = [NSString stringWithFormat:
        @"SELECT cwd, COALESCE(rollout_path,''), tokens_used, created_at "
         "FROM threads WHERE updated_at >= %lld;",
        startEpoch
    ];

    NSTask *task = [NSTask new];
    NSPipe *output = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/sqlite3"];
    task.arguments = @[@"-separator", @"\t", databaseURL.path, query];
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    if (![task launchAndReturnError:nil]) {
        return @{@"project": @0, @"total": @0};
    }
    [task waitUntilExit];

    NSData *resultData =
        [output.fileHandleForReading readDataToEndOfFile];
    NSString *rows = [[NSString alloc]
        initWithData:resultData
        encoding:NSUTF8StringEncoding];
    __block long long projectTokens = 0;
    __block long long totalTokens = 0;
    NSString *standardizedProjectPath =
        projectPath.stringByStandardizingPath;

    [rows enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSArray<NSString *> *fields =
            [line componentsSeparatedByString:@"\t"];
        if (fields.count < 4) return;

        NSString *cwd = fields[0];
        NSString *rolloutPath = fields[1];
        long long storedTokens = fields[2].longLongValue;
        long long createdAt = fields[3].longLongValue;
        long long weeklyTokens = storedTokens;

        if (createdAt < startEpoch && rolloutPath.length > 0) {
            weeklyTokens = [self tokensSince:windowStart
                                  rolloutPath:rolloutPath
                                 currentTotal:storedTokens];
        }

        weeklyTokens = MAX(0, weeklyTokens);
        totalTokens += weeklyTokens;
        if (PathBelongsToProject(
                cwd,
                standardizedProjectPath
            )) {
            projectTokens += weeklyTokens;
        }
    }];

    return @{@"project": @(projectTokens), @"total": @(totalTokens)};
}

- (long long)tokensSince:(NSDate *)windowStart
             rolloutPath:(NSString *)rolloutPath
            currentTotal:(long long)currentTotal {
    NSString *contents =
        [NSString stringWithContentsOfFile:rolloutPath
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if (!contents) return currentTotal;

    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions =
        NSISO8601DateFormatWithInternetDateTime |
        NSISO8601DateFormatWithFractionalSeconds;
    NSString *windowStartText = [formatter stringFromDate:windowStart];

    __block long long baseline = 0;
    __block long long latest = 0;
    [contents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        if ([line rangeOfString:@"\"type\":\"token_count\""].location ==
            NSNotFound) {
            return;
        }

        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        id event =
            [NSJSONSerialization JSONObjectWithData:data
                                            options:0
                                              error:nil];
        NSString *timestamp =
            [event isKindOfClass:[NSDictionary class]] &&
            [event[@"timestamp"] isKindOfClass:[NSString class]]
                ? event[@"timestamp"]
                : nil;
        NSNumber *tokens = TotalTokensFromRolloutEvent(event);
        if (![timestamp isKindOfClass:[NSString class]] ||
            ![tokens isKindOfClass:[NSNumber class]]) {
            return;
        }

        if ([timestamp compare:windowStartText] == NSOrderedAscending) {
            baseline = tokens.longLongValue;
        } else {
            latest = tokens.longLongValue;
        }
    }];

    if (latest == 0) latest = currentTotal;
    return MAX(0, latest - baseline);
}

- (nullable QuotaSnapshot *)loadQuota {
    NSString *binaryPath =
        @"/Applications/ChatGPT.app/Contents/Resources/codex";
    if (![[NSFileManager defaultManager]
            isExecutableFileAtPath:binaryPath]) {
        return nil;
    }

    NSTask *task = [NSTask new];
    NSPipe *input = [NSPipe pipe];
    NSPipe *output = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:binaryPath];
    task.arguments = @[@"app-server", @"--stdio"];
    task.standardInput = input;
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return nil;

    NSFileHandle *writer = input.fileHandleForWriting;
    NSFileHandle *reader = output.fileHandleForReading;
    NSString *appVersion =
        [NSBundle.mainBundle.infoDictionary
            objectForKey:@"CFBundleShortVersionString"];
    if (appVersion.length == 0) appVersion = @"development";
    NSDictionary *initialize = @{
        @"method": @"initialize",
        @"id": @1,
        @"params": @{
            @"clientInfo": @{
                @"name": @"codex-quota-menu",
                @"title": @"Codex Quota Menu",
                @"version": appVersion
            },
            @"capabilities": @{
                @"experimentalApi": @YES,
                @"requestAttestation": @NO
            }
        }
    };

    if (![self writeMessage:initialize to:writer] ||
        ![self readResponseWithId:1 from:reader]) {
        [task terminate];
        return nil;
    }

    [self writeMessage:@{@"method": @"initialized"} to:writer];
    [self writeMessage:@{
        @"method": @"account/rateLimits/read",
        @"id": @2
    } to:writer];
    NSDictionary *rateResponse =
        [self readResponseWithId:2 from:reader];

    [self writeMessage:@{
        @"method": @"account/usage/read",
        @"id": @3
    } to:writer];
    NSDictionary *usageResponse =
        [self readResponseWithId:3 from:reader];

    [writer closeFile];
    if (task.running) [task terminate];

    NSDictionary *primary =
        rateResponse[@"result"][@"rateLimits"][@"primary"];
    NSNumber *usedPercent = primary[@"usedPercent"];
    if (![usedPercent isKindOfClass:[NSNumber class]]) return nil;

    QuotaSnapshot *snapshot = [QuotaSnapshot new];
    snapshot.usedPercent = usedPercent.doubleValue;

    NSNumber *resetEpoch = primary[@"resetsAt"];
    if ([resetEpoch isKindOfClass:[NSNumber class]]) {
        snapshot.resetsAt =
            [NSDate dateWithTimeIntervalSince1970:resetEpoch.doubleValue];
    }

    NSNumber *windowDuration = primary[@"windowDurationMins"];
    snapshot.windowDurationMinutes =
        windowDuration.integerValue > 0
            ? windowDuration.integerValue
            : 10080;
    NSNumber *lifetimeTokens =
        usageResponse[@"result"][@"summary"][@"lifetimeTokens"];
    if ([lifetimeTokens isKindOfClass:[NSNumber class]] &&
        lifetimeTokens.longLongValue > 0) {
        snapshot.lifetimeTokens = lifetimeTokens.longLongValue;
        [NSUserDefaults.standardUserDefaults
            setObject:lifetimeTokens
               forKey:@"CodexQuotaLastLifetimeTokens"];
    } else {
        NSNumber *cached =
            [NSUserDefaults.standardUserDefaults
                objectForKey:@"CodexQuotaLastLifetimeTokens"];
        snapshot.lifetimeTokens =
            [cached isKindOfClass:[NSNumber class]] &&
            cached.longLongValue > 0
                ? cached.longLongValue
                : [self localLifetimeTokens];
    }
    return snapshot;
}

- (long long)localLifetimeTokens {
    NSURL *databaseURL =
        [[self codexHome] URLByAppendingPathComponent:@"state_5.sqlite"];
    if (![[NSFileManager defaultManager]
            fileExistsAtPath:databaseURL.path]) {
        return 0;
    }

    NSTask *task = [NSTask new];
    NSPipe *output = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/sqlite3"];
    task.arguments = @[
        databaseURL.path,
        @"SELECT COALESCE(SUM(tokens_used),0) FROM threads;"
    ];
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return 0;
    [task waitUntilExit];

    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    NSString *value = [[NSString alloc]
        initWithData:data
        encoding:NSUTF8StringEncoding];
    return MAX(0, value.longLongValue);
}

- (BOOL)writeMessage:(NSDictionary *)message
                   to:(NSFileHandle *)handle {
    NSData *data =
        [NSJSONSerialization dataWithJSONObject:message
                                        options:0
                                          error:nil];
    if (!data) return NO;
    [handle writeData:data];
    [handle writeData:[NSData dataWithBytes:"\n" length:1]];
    return YES;
}

- (nullable NSDictionary *)readResponseWithId:(NSInteger)requestId
                                          from:(NSFileHandle *)handle {
    NSDate *deadline =
        [NSDate dateWithTimeIntervalSinceNow:AppServerResponseTimeout];
    while (YES) {
        NSTimeInterval remaining =
            [deadline timeIntervalSinceDate:NSDate.date];
        if (remaining <= 0) return nil;
        NSData *line = [self readLineFrom:handle timeout:remaining];
        if (!line) return nil;
        NSDictionary *object =
            [NSJSONSerialization JSONObjectWithData:line
                                            options:0
                                              error:nil];
        if (![object isKindOfClass:[NSDictionary class]]) continue;
        if ([object[@"id"] integerValue] == requestId) {
            return object[@"error"] ? nil : object;
        }
    }
}

- (nullable NSData *)readLineFrom:(NSFileHandle *)handle
                          timeout:(NSTimeInterval)timeout {
    NSMutableData *line = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    int fileDescriptor = handle.fileDescriptor;
    while (YES) {
        NSTimeInterval remaining =
            [deadline timeIntervalSinceDate:NSDate.date];
        if (remaining <= 0) return nil;

        int timeoutMilliseconds =
            (int)ceil(MIN(remaining, 60.0) * 1000.0);
        struct pollfd descriptor = {
            .fd = fileDescriptor,
            .events = POLLIN,
            .revents = 0
        };
        int pollResult;
        do {
            pollResult = poll(&descriptor, 1, timeoutMilliseconds);
        } while (pollResult < 0 && errno == EINTR);
        if (pollResult <= 0 ||
            !(descriptor.revents & (POLLIN | POLLHUP))) {
            return nil;
        }

        NSData *byte = [handle readDataOfLength:1];
        if (byte.length == 0) return nil;
        if (((const unsigned char *)byte.bytes)[0] == '\n') return line;
        [line appendData:byte];
    }
}

@end

static double ProjectShare(ProjectSnapshot *project) {
    if (!project || project.weeklyTotalTokens <= 0) return 0;
    return (double)project.weeklyProjectTokens /
        (double)project.weeklyTotalTokens * 100.0;
}

static NSString *CompactStatusText(QuotaSnapshot *quota,
                                   ProjectSnapshot *project) {
    if (!quota && !project) return @"额度与 Token 读取中";
    if (!quota) {
        return [NSString stringWithFormat:
            @"额度读取中 · 当前项目 %@",
            FormatTokens(project.weeklyProjectTokens)
        ];
    }
    if (!project) {
        return [NSString stringWithFormat:
            @"剩余 %.0f%% · 项目读取中",
            quota.remainingPercent
        ];
    }

    return [NSString stringWithFormat:
        @"剩余 %.0f%% · 当前项目 %@ · 本周 %@",
        quota.remainingPercent,
        FormatTokens(project.weeklyProjectTokens),
        FormatTokens(project.weeklyTotalTokens)
    ];
}

static NSString *FloatingSummaryText(QuotaSnapshot *quota,
                                     ProjectSnapshot *project) {
    if (!quota && !project) return @"额度与 Token 读取中";
    if (!quota) {
        return [NSString stringWithFormat:
            @"额度读取中 ｜ %@项目本周消耗 %@ / %@ · 占比 %.1f%% "
             "｜ 总消耗 Token 读取中",
            project.name,
            FormatTokens(project.weeklyProjectTokens),
            FormatTokens(project.weeklyTotalTokens),
            ProjectShare(project)
        ];
    }
    if (!project) {
        return [NSString stringWithFormat:
            @"额度剩余 %.0f%% ｜ 项目读取中 ｜ 总消耗 Token %@",
            quota.remainingPercent,
            FormatLifetimeTokens(quota.lifetimeTokens)
        ];
    }
    return [NSString stringWithFormat:
        @"额度剩余 %.0f%% ｜ %@项目本周消耗 %@ / %@ · 占比 %.1f%% "
         "｜ 总消耗 Token %@",
        quota.remainingPercent,
        project.name,
        FormatTokens(project.weeklyProjectTokens),
        FormatTokens(project.weeklyTotalTokens),
        ProjectShare(project),
        FormatLifetimeTokens(quota.lifetimeTokens)
    ];
}

static const CGFloat HUDBaseWidth = 400;
static const CGFloat HUDBaseCollapsedHeight = 104;
static const CGFloat HUDBaseExpandedHeight = 336;
static const CGFloat HUDDefaultScale = 0.82;
static const CGFloat HUDMinimumScale = 0.65;
static const CGFloat HUDMaximumScale = 1.25;
static const CGFloat HUDBaseBallDiameter = 88;
static const CGFloat HUDDockThreshold = 10;
static const CGFloat HUDDockMargin = 4;

typedef NS_ENUM(NSInteger, HUDDockSide) {
    HUDDockSideNone = 0,
    HUDDockSideLeft = 1,
    HUDDockSideRight = 2,
    HUDDockSideBottom = 3,
    HUDDockSideTop = 4
};

static CGFloat HUDClampedScale(CGFloat scale) {
    return MIN(HUDMaximumScale, MAX(HUDMinimumScale, scale));
}

static NSRect HUDFrameForExpansion(
    NSRect frame,
    BOOL expanded,
    CGFloat maximumHeight,
    CGFloat scale
) {
    scale = HUDClampedScale(scale);
    CGFloat topEdge = NSMaxY(frame);
    CGFloat targetHeight =
        expanded
            ? MIN(HUDBaseExpandedHeight * scale, maximumHeight)
            : HUDBaseCollapsedHeight * scale;
    frame.size.width = HUDBaseWidth * scale;
    frame.size.height = targetHeight;
    frame.origin.y = topEdge - targetHeight;
    return frame;
}

static HUDDockSide HUDDockSideNearFrame(
    NSRect frame,
    NSRect visibleFrame
) {
    CGFloat distances[] = {
        CGFLOAT_MAX,
        MAX(0, NSMinX(frame) - NSMinX(visibleFrame)),
        MAX(0, NSMaxX(visibleFrame) - NSMaxX(frame)),
        MAX(0, NSMinY(frame) - NSMinY(visibleFrame)),
        MAX(0, NSMaxY(visibleFrame) - NSMaxY(frame))
    };
    HUDDockSide nearest = HUDDockSideNone;
    CGFloat nearestDistance = CGFLOAT_MAX;
    for (NSInteger side = HUDDockSideLeft;
         side <= HUDDockSideTop;
         side++) {
        if (distances[side] < nearestDistance) {
            nearestDistance = distances[side];
            nearest = (HUDDockSide)side;
        }
    }
    return nearestDistance <= HUDDockThreshold
        ? nearest
        : HUDDockSideNone;
}

static NSRect HUDBallFrameForDock(
    NSRect sourceFrame,
    NSRect visibleFrame,
    HUDDockSide side,
    CGFloat scale
) {
    CGFloat diameter = HUDBaseBallDiameter * HUDClampedScale(scale);
    CGFloat margin = HUDDockMargin * HUDClampedScale(scale);
    NSRect frame = NSMakeRect(
        NSMidX(sourceFrame) - diameter / 2,
        NSMidY(sourceFrame) - diameter / 2,
        diameter,
        diameter
    );
    frame.origin.x = MIN(
        MAX(frame.origin.x, NSMinX(visibleFrame) + margin),
        NSMaxX(visibleFrame) - diameter - margin
    );
    frame.origin.y = MIN(
        MAX(frame.origin.y, NSMinY(visibleFrame) + margin),
        NSMaxY(visibleFrame) - diameter - margin
    );
    switch (side) {
        case HUDDockSideLeft:
            frame.origin.x = NSMinX(visibleFrame) + margin;
            break;
        case HUDDockSideRight:
            frame.origin.x =
                NSMaxX(visibleFrame) - diameter - margin;
            break;
        case HUDDockSideBottom:
            frame.origin.y = NSMinY(visibleFrame) + margin;
            break;
        case HUDDockSideTop:
            frame.origin.y =
                NSMaxY(visibleFrame) - diameter - margin;
            break;
        case HUDDockSideNone:
            break;
    }
    return frame;
}

@interface AdaptiveHUDMaterialView : NSView
@property(nonatomic) BOOL circular;
@end

@implementation AdaptiveHUDMaterialView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.layer.cornerRadius =
        15 * (NSWidth(frame) / HUDBaseWidth);
    self.layer.masksToBounds = YES;
    self.layer.backgroundColor = NSColor.clearColor.CGColor;
    return self;
}

- (void)layout {
    [super layout];
    CGFloat scale = NSWidth(self.bounds) / HUDBaseWidth;
    self.layer.cornerRadius =
        self.circular
            ? NSHeight(self.bounds) / 2
            : 15 * scale;
    [self setNeedsDisplay:YES];
}

- (void)setCircular:(BOOL)circular {
    _circular = circular;
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    CGFloat scale = NSWidth(self.bounds) / HUDBaseWidth;
    NSColor *surface =
        [NSColor colorWithSRGBRed:0.075
                           green:0.082
                            blue:0.094
                           alpha:0.97];
    NSColor *stroke =
        [NSColor colorWithWhite:1.0 alpha:0.115];
    CGFloat strokeWidth = MAX(0.75, scale);
    NSRect strokeRect =
        NSInsetRect(self.bounds, strokeWidth / 2, strokeWidth / 2);
    NSBezierPath *shape =
        self.circular
            ? [NSBezierPath bezierPathWithOvalInRect:strokeRect]
            : [NSBezierPath bezierPathWithRoundedRect:strokeRect
                                              xRadius:14.5 * scale
                                              yRadius:14.5 * scale];
    [surface setFill];
    [shape fill];
    shape.lineWidth = strokeWidth;
    [stroke setStroke];
    [shape stroke];

    CGFloat collapsedHeight = HUDBaseCollapsedHeight * scale;
    if (!self.circular &&
        NSHeight(self.bounds) > collapsedHeight + 1) {
        NSColor *separator =
            [NSColor colorWithWhite:1.0 alpha:0.075];
        [separator setStroke];
        NSBezierPath *line = [NSBezierPath bezierPath];
        line.lineWidth = strokeWidth;
        CGFloat y =
            NSHeight(self.bounds) - collapsedHeight + strokeWidth / 2;
        [line moveToPoint:NSMakePoint(14 * scale, y)];
        [line lineToPoint:
            NSMakePoint(NSWidth(self.bounds) - 14 * scale, y)];
        [line stroke];
    }
}

@end

@interface QuotaStatusBallView : NSView
- (void)updateRemainingPercent:(double)remainingPercent
                     available:(BOOL)available
                   accentColor:(NSColor *)accentColor;
@end

@implementation QuotaStatusBallView {
    double _remainingPercent;
    BOOL _available;
    NSColor *_accentColor;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _accentColor = NSColor.systemGreenColor;
    return self;
}

- (void)updateRemainingPercent:(double)remainingPercent
                     available:(BOOL)available
                   accentColor:(NSColor *)accentColor {
    _remainingPercent = MIN(100, MAX(0, remainingPercent));
    _available = available;
    _accentColor = accentColor ?: NSColor.systemGreenColor;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    CGFloat scale =
        MIN(NSWidth(self.bounds), NSHeight(self.bounds)) /
        HUDBaseBallDiameter;
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform scaleBy:scale];
    [transform concat];

    NSPoint center = NSMakePoint(44, 44);
    CGFloat radius = 32;
    CGFloat width = 7;
    NSBezierPath *track = [NSBezierPath bezierPath];
    [track appendBezierPathWithOvalInRect:
        NSMakeRect(
            center.x - radius,
            center.y - radius,
            radius * 2,
            radius * 2
        )];
    track.lineWidth = width;
    [[NSColor colorWithWhite:1.0 alpha:0.12] setStroke];
    [track stroke];

    if (_available && _remainingPercent > 0) {
        NSBezierPath *progress = [NSBezierPath bezierPath];
        progress.lineWidth = width;
        progress.lineCapStyle = NSLineCapStyleRound;
        [progress appendBezierPathWithArcWithCenter:center
                                             radius:radius
                                         startAngle:90
                                           endAngle:
                                               90 - 360 *
                                               (_remainingPercent / 100.0)
                                          clockwise:YES];
        [_accentColor setStroke];
        [progress stroke];
    }

    NSString *text =
        _available
            ? [NSString stringWithFormat:@"%.0f%%", _remainingPercent]
            : @"--";
    NSDictionary *attributes = @{
        NSFontAttributeName:
            [NSFont monospacedDigitSystemFontOfSize:17
                                             weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName:
            [NSColor colorWithWhite:1.0 alpha:0.94]
    };
    NSSize size = [text sizeWithAttributes:attributes];
    [text drawAtPoint:
        NSMakePoint(
            floor(center.x - size.width / 2),
            floor(center.y - size.height / 2)
        )
        withAttributes:attributes];
    [NSGraphicsContext restoreGraphicsState];
}

@end

@interface QuotaGaugeView : NSView
- (void)updateRemainingPercent:(double)remainingPercent
                     available:(BOOL)available
                   accentColor:(NSColor *)accentColor;
@end

@implementation QuotaGaugeView {
    double _remainingPercent;
    BOOL _available;
    NSColor *_accentColor;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _accentColor = NSColor.systemGreenColor;
    return self;
}

- (void)updateRemainingPercent:(double)remainingPercent
                     available:(BOOL)available
                   accentColor:(NSColor *)accentColor {
    _remainingPercent = MIN(100, MAX(0, remainingPercent));
    _available = available;
    _accentColor = accentColor ?: NSColor.systemGreenColor;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGFloat scale =
        MIN(
            NSWidth(self.bounds) / HUDBaseWidth,
            NSHeight(self.bounds) / HUDBaseCollapsedHeight
        );
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform scaleBy:scale];
    [transform concat];

    NSPoint ringCenter = NSMakePoint(66, 52);
    CGFloat ringRadius = 38;
    CGFloat ringWidth = 8;
    NSBezierPath *track = [NSBezierPath bezierPath];
    [track appendBezierPathWithOvalInRect:NSMakeRect(
        ringCenter.x - ringRadius,
        ringCenter.y - ringRadius,
        ringRadius * 2,
        ringRadius * 2
    )];
    track.lineWidth = ringWidth;
    [[NSColor colorWithWhite:1.0 alpha:0.11] setStroke];
    [track stroke];

    if (_available && _remainingPercent > 0) {
        NSBezierPath *progress = [NSBezierPath bezierPath];
        progress.lineWidth = ringWidth;
        progress.lineCapStyle = NSLineCapStyleRound;
        [progress appendBezierPathWithArcWithCenter:ringCenter
                                             radius:ringRadius
                                         startAngle:90
                                           endAngle:
                                               90 - 360 *
                                               (_remainingPercent / 100.0)
                                          clockwise:YES];
        [_accentColor setStroke];
        [progress stroke];
    }

    NSString *percentText =
        _available
            ? [NSString stringWithFormat:@"%.0f%%", _remainingPercent]
            : @"--%";
    NSDictionary *percentAttributes = @{
        NSFontAttributeName:
            [NSFont monospacedDigitSystemFontOfSize:22
                                             weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName:
            [NSColor colorWithWhite:1.0 alpha:0.94]
    };
    NSSize percentSize =
        [percentText sizeWithAttributes:percentAttributes];
    [percentText drawAtPoint:NSMakePoint(
        floor(ringCenter.x - percentSize.width / 2),
        floor(ringCenter.y - percentSize.height / 2)
    ) withAttributes:percentAttributes];

    NSString *title = _available ? @"额度剩余" : @"额度读取中";
    NSDictionary *titleAttributes = @{
        NSFontAttributeName:
            [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName:
            [NSColor colorWithWhite:1.0 alpha:0.94]
    };
    [title drawAtPoint:NSMakePoint(124, 64)
        withAttributes:titleAttributes];

    NSString *subtitle =
        _available
            ? [NSString stringWithFormat:
                @"本周期已用 %.0f%% / 100%%",
                100 - _remainingPercent]
            : @"正在连接 Codex";
    NSDictionary *subtitleAttributes = @{
        NSFontAttributeName:
            [NSFont monospacedDigitSystemFontOfSize:12.5
                                             weight:NSFontWeightMedium],
        NSForegroundColorAttributeName:
            [NSColor colorWithWhite:1.0 alpha:0.62]
    };
    [subtitle drawAtPoint:NSMakePoint(124, 39)
           withAttributes:subtitleAttributes];

    NSRect progressTrack = NSMakeRect(124, 18, 252, 7);
    NSBezierPath *barTrack =
        [NSBezierPath bezierPathWithRoundedRect:progressTrack
                                        xRadius:3.5
                                        yRadius:3.5];
    [[NSColor colorWithWhite:1.0 alpha:0.10] setFill];
    [barTrack fill];
    if (_available && _remainingPercent > 0) {
        NSRect progressFill = progressTrack;
        progressFill.size.width =
            MAX(7, NSWidth(progressTrack) *
                   (_remainingPercent / 100.0));
        NSBezierPath *barFill =
            [NSBezierPath bezierPathWithRoundedRect:progressFill
                                            xRadius:3.5
                                            yRadius:3.5];
        [_accentColor setFill];
        [barFill fill];
    }
    [NSGraphicsContext restoreGraphicsState];
}

@end

@interface HUDMetricRowView : NSView
- (instancetype)initWithSymbolName:(NSString *)symbolName
                       accentColor:(NSColor *)accentColor;
- (void)updateTitle:(NSString *)title
              value:(NSString *)value
           trailing:(nullable NSString *)trailing;
@end

@implementation HUDMetricRowView {
    NSImageView *_iconView;
    NSTextField *_titleLabel;
    NSTextField *_valueLabel;
    NSTextField *_trailingLabel;
}

- (instancetype)initWithSymbolName:(NSString *)symbolName
                       accentColor:(NSColor *)accentColor {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    NSImage *image =
        [NSImage imageWithSystemSymbolName:symbolName
                  accessibilityDescription:nil];
    NSImageSymbolConfiguration *configuration =
        [NSImageSymbolConfiguration
            configurationWithPointSize:15
                                weight:NSFontWeightMedium];
    _iconView.image = [image imageWithSymbolConfiguration:configuration];
    _iconView.contentTintColor = accentColor;
    _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:_iconView];

    _titleLabel = [NSTextField labelWithString:@""];
    _titleLabel.font =
        [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    _titleLabel.textColor =
        [NSColor colorWithWhite:1.0 alpha:0.56];
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_titleLabel];

    _valueLabel = [NSTextField labelWithString:@""];
    _valueLabel.font =
        [NSFont monospacedDigitSystemFontOfSize:13.5
                                         weight:NSFontWeightSemibold];
    _valueLabel.textColor =
        [NSColor colorWithWhite:1.0 alpha:0.92];
    _valueLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self addSubview:_valueLabel];

    _trailingLabel = [NSTextField labelWithString:@""];
    _trailingLabel.font =
        [NSFont monospacedDigitSystemFontOfSize:13.5
                                         weight:NSFontWeightMedium];
    _trailingLabel.textColor =
        [NSColor colorWithWhite:1.0 alpha:0.64];
    _trailingLabel.alignment = NSTextAlignmentRight;
    [self addSubview:_trailingLabel];
    return self;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    CGFloat scale = height / 64.0;
    CGFloat trailingWidth =
        _trailingLabel.stringValue.length > 0 ? 66 * scale : 0;
    _titleLabel.font =
        [NSFont systemFontOfSize:10.5 * scale
                          weight:NSFontWeightMedium];
    _valueLabel.font =
        [NSFont monospacedDigitSystemFontOfSize:13.5 * scale
                                         weight:NSFontWeightSemibold];
    _trailingLabel.font =
        [NSFont monospacedDigitSystemFontOfSize:13.5 * scale
                                         weight:NSFontWeightMedium];
    _iconView.frame =
        NSMakeRect(
            17 * scale,
            floor((height - 20 * scale) / 2),
            20 * scale,
            20 * scale
        );
    _titleLabel.frame =
        NSMakeRect(
            50 * scale,
            height - 24 * scale,
            width - 66 * scale - trailingWidth,
            15 * scale
        );
    _valueLabel.frame =
        NSMakeRect(
            50 * scale,
            9 * scale,
            width - 66 * scale - trailingWidth,
            20 * scale
        );
    _trailingLabel.frame =
        NSMakeRect(
            width - 78 * scale,
            floor((height - 20 * scale) / 2),
            62 * scale,
            20 * scale
        );
}

- (void)updateTitle:(NSString *)title
              value:(NSString *)value
           trailing:(nullable NSString *)trailing {
    _titleLabel.stringValue = title ?: @"";
    _valueLabel.stringValue = value ?: @"--";
    _trailingLabel.stringValue = trailing ?: @"";
    [self setNeedsLayout:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    CGFloat scale = NSHeight(self.bounds) / 64.0;
    NSColor *fill =
        [NSColor colorWithWhite:1.0 alpha:0.045];
    NSColor *stroke =
        [NSColor colorWithWhite:1.0 alpha:0.065];
    NSBezierPath *shape =
        [NSBezierPath bezierPathWithRoundedRect:
            NSInsetRect(self.bounds, 0.5 * scale, 0.5 * scale)
                                        xRadius:10 * scale
                                        yRadius:10 * scale];
    [fill setFill];
    [shape fill];
    shape.lineWidth = MAX(0.75, scale);
    [stroke setStroke];
    [shape stroke];
}

@end

@interface HoverRevealView : NSView
@property(nonatomic) BOOL expanded;
@property(nonatomic) BOOL suppressHoverExit;
@property(nonatomic, copy) void (^onHoverChanged)(BOOL expanded);
@property(nonatomic, copy) void (^onDrag)(NSPoint delta);
@property(nonatomic, copy) void (^onDragEnd)(void);
@end

@implementation HoverRevealView {
    NSTrackingArea *_trackingArea;
    NSPoint _lastMouseLocation;
    BOOL _dragging;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    _trackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited |
                     NSTrackingActiveAlways |
                     NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    if (self.onHoverChanged) self.onHoverChanged(YES);
}

- (void)mouseExited:(NSEvent *)event {
    if (_dragging || self.suppressHoverExit) return;
    if (self.onHoverChanged) self.onHoverChanged(NO);
}

- (void)mouseDown:(NSEvent *)event {
    _dragging = YES;
    _lastMouseLocation = NSEvent.mouseLocation;
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint current = NSEvent.mouseLocation;
    NSPoint delta = NSMakePoint(
        current.x - _lastMouseLocation.x,
        current.y - _lastMouseLocation.y
    );
    _lastMouseLocation = current;
    if (self.onDrag) self.onDrag(delta);
}

- (void)mouseUp:(NSEvent *)event {
    _dragging = NO;
    if (self.onDragEnd) self.onDragEnd();
}

- (void)setExpanded:(BOOL)expanded {
    _expanded = expanded;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
}

@end

@interface ResizeGripView : NSView
@property(nonatomic, copy) void (^onResizeBegin)(void);
@property(nonatomic, copy) void (^onResize)(NSPoint delta);
@property(nonatomic, copy) void (^onResizeEnd)(void);
@end

@implementation ResizeGripView {
    NSPoint _lastMouseLocation;
    BOOL _resizing;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds
                 cursor:NSCursor.resizeLeftRightCursor];
}

- (void)mouseDown:(NSEvent *)event {
    _resizing = YES;
    _lastMouseLocation = NSEvent.mouseLocation;
    if (self.onResizeBegin) self.onResizeBegin();
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint current = NSEvent.mouseLocation;
    NSPoint delta = NSMakePoint(
        current.x - _lastMouseLocation.x,
        current.y - _lastMouseLocation.y
    );
    _lastMouseLocation = current;
    if (self.onResize) self.onResize(delta);
}

- (void)mouseUp:(NSEvent *)event {
    if (!_resizing) return;
    _resizing = NO;
    if (self.onResizeEnd) self.onResizeEnd();
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [[NSColor colorWithWhite:1.0 alpha:0.34] setStroke];
    NSBezierPath *grip = [NSBezierPath bezierPath];
    grip.lineWidth = 1.25;
    grip.lineCapStyle = NSLineCapStyleRound;
    for (NSInteger index = 0; index < 3; index++) {
        CGFloat inset = 5 + index * 4;
        [grip moveToPoint:
            NSMakePoint(NSWidth(self.bounds) - inset, 4)];
        [grip lineToPoint:
            NSMakePoint(NSWidth(self.bounds) - 4, inset)];
    }
    [grip stroke];
}

@end

@interface FloatingQuotaController : NSObject
@end

@implementation FloatingQuotaController {
    NSPanel *_panel;
    NSPanel *_hoverPanel;
    AdaptiveHUDMaterialView *_material;
    HoverRevealView *_hoverRevealView;
    ResizeGripView *_resizeGrip;
    NSView *_detailsContainer;
    QuotaGaugeView *_quotaGauge;
    QuotaStatusBallView *_statusBall;
    HUDMetricRowView *_projectRow;
    HUDMetricRowView *_weeklyTotalRow;
    HUDMetricRowView *_lifetimeRow;
    CodexDataSource *_dataSource;
    NSTimer *_timer;
    QuotaSnapshot *_quota;
    ProjectSnapshot *_project;
    NSDate *_lastQuotaAttempt;
    BOOL _refreshInFlight;
    BOOL _positionInitialized;
    BOOL _detailsExpanded;
    CGFloat _hudScale;
    HUDDockSide _dockSide;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _dataSource = [CodexDataSource new];
    _lastQuotaAttempt = [NSDate distantPast];
    [self configurePanel];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(activeApplicationChanged:)
               name:NSWorkspaceDidActivateApplicationNotification
             object:nil];
    [self refresh];
    [self updateVisibility];
    _timer = [NSTimer scheduledTimerWithTimeInterval:5
                                              target:self
                                            selector:@selector(refresh)
                                            userInfo:nil
                                             repeats:YES];
    return self;
}

- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        removeObserver:self];
}

- (void)configurePanel {
    _detailsExpanded = NO;
    NSNumber *savedScale =
        [NSUserDefaults.standardUserDefaults
            objectForKey:@"CodexQuotaGaugeScale"];
    _hudScale =
        savedScale
            ? HUDClampedScale(savedScale.doubleValue)
            : HUDDefaultScale;
    NSInteger savedDockSide =
        [NSUserDefaults.standardUserDefaults
            integerForKey:@"CodexQuotaGaugeDockSide"];
    _dockSide =
        savedDockSide >= HUDDockSideLeft &&
        savedDockSide <= HUDDockSideTop
            ? (HUDDockSide)savedDockSide
            : HUDDockSideNone;
    CGFloat initialWidth =
        _dockSide == HUDDockSideNone
            ? HUDBaseWidth * _hudScale
            : HUDBaseBallDiameter * _hudScale;
    CGFloat initialHeight =
        _dockSide == HUDDockSideNone
            ? HUDBaseCollapsedHeight * _hudScale
            : HUDBaseBallDiameter * _hudScale;
    NSRect frame = NSMakeRect(
        0,
        0,
        initialWidth,
        initialHeight
    );
    _panel = [[NSPanel alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskBorderless |
                            NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = YES;
    _panel.level = NSFloatingWindowLevel;
    _panel.hidesOnDeactivate = NO;
    _panel.ignoresMouseEvents = YES;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorTransient |
        NSWindowCollectionBehaviorIgnoresCycle;

    _material = [[AdaptiveHUDMaterialView alloc] initWithFrame:frame];
    _material.circular = _dockSide != HUDDockSideNone;
    _material.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable;
    _panel.contentView = _material;

    __weak FloatingQuotaController *weakSelf = self;
    _hoverPanel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(
            0,
            0,
            NSWidth(frame),
            NSHeight(frame)
        )
                  styleMask:NSWindowStyleMaskBorderless |
                            NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    _hoverPanel.opaque = NO;
    _hoverPanel.backgroundColor = NSColor.clearColor;
    _hoverPanel.hasShadow = NO;
    _hoverPanel.level = NSFloatingWindowLevel;
    _hoverPanel.hidesOnDeactivate = NO;
    _hoverPanel.ignoresMouseEvents = NO;
    _hoverPanel.becomesKeyOnlyIfNeeded = YES;
    _hoverPanel.collectionBehavior = _panel.collectionBehavior;

    _hoverRevealView = [[HoverRevealView alloc]
        initWithFrame:NSMakeRect(
            0,
            0,
            NSWidth(frame),
            NSHeight(frame)
        )];
    _hoverRevealView.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable;
    _hoverRevealView.accessibilityElement = YES;
    _hoverRevealView.accessibilityLabel = @"鼠标悬停显示额度详情";
    _hoverRevealView.onHoverChanged = ^(BOOL expanded) {
        FloatingQuotaController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_dockSide != HUDDockSideNone) return;
        [strongSelf setDetailsExpanded:expanded];
    };
    _hoverRevealView.onDrag = ^(NSPoint delta) {
        FloatingQuotaController *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSRect panelFrame = strongSelf->_panel.frame;
        panelFrame.origin.x += delta.x;
        panelFrame.origin.y += delta.y;
        [strongSelf->_panel setFrameOrigin:panelFrame.origin];
    };
    _hoverRevealView.onDragEnd = ^{
        FloatingQuotaController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf finishPanelDrag];
    };
    _hoverPanel.contentView = _hoverRevealView;
    [_panel addChildWindow:_hoverPanel ordered:NSWindowAbove];

    _resizeGrip =
        [[ResizeGripView alloc] initWithFrame:NSZeroRect];
    _resizeGrip.hidden = YES;
    _resizeGrip.accessibilityElement = YES;
    _resizeGrip.accessibilityLabel =
        @"拖动以等比调整额度浮窗大小";
    _resizeGrip.onResizeBegin = ^{
        FloatingQuotaController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_hoverRevealView.suppressHoverExit = YES;
    };
    _resizeGrip.onResize = ^(NSPoint delta) {
        FloatingQuotaController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf resizeHUDByDelta:delta];
    };
    _resizeGrip.onResizeEnd = ^{
        FloatingQuotaController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_hoverRevealView.suppressHoverExit = NO;
        [strongSelf constrainPanelToVisibleScreen];
        [strongSelf savePanelPosition];
        [strongSelf saveHUDScale];
    };
    [_hoverRevealView addSubview:_resizeGrip];

    _quotaGauge = [[QuotaGaugeView alloc]
        initWithFrame:NSMakeRect(
            0,
            0,
            NSWidth(frame),
            NSHeight(frame)
        )];
    _quotaGauge.accessibilityElement = YES;
    _quotaGauge.accessibilityLabel = @"Codex 额度剩余";
    [_material addSubview:_quotaGauge];

    _statusBall =
        [[QuotaStatusBallView alloc] initWithFrame:NSZeroRect];
    _statusBall.hidden = _dockSide == HUDDockSideNone;
    _statusBall.accessibilityElement = YES;
    _statusBall.accessibilityLabel =
        @"Codex 额度状态球，拖离屏幕边缘恢复完整卡片";
    [_material addSubview:_statusBall];

    _detailsContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    _detailsContainer.hidden = YES;
    [_material addSubview:_detailsContainer];

    _projectRow = [[HUDMetricRowView alloc]
        initWithSymbolName:@"folder.fill"
               accentColor:
                   [NSColor colorWithWhite:1.0 alpha:0.50]];
    [_detailsContainer addSubview:_projectRow];

    _weeklyTotalRow = [[HUDMetricRowView alloc]
        initWithSymbolName:@"square.stack.3d.up.fill"
               accentColor:
                   [NSColor colorWithWhite:1.0 alpha:0.50]];
    [_detailsContainer addSubview:_weeklyTotalRow];

    _lifetimeRow = [[HUDMetricRowView alloc]
        initWithSymbolName:@"chart.line.uptrend.xyaxis"
               accentColor:
                   [NSColor colorWithWhite:1.0 alpha:0.50]];
    [_detailsContainer addSubview:_lifetimeRow];

    [self applyDockPresentation];
    [self layoutHUDSubviews];
    [self updateContent];
}

- (void)activeApplicationChanged:(NSNotification *)notification {
    [self updateVisibility];
}

- (BOOL)isCodexFrontmost {
    NSString *bundleIdentifier =
        NSWorkspace.sharedWorkspace
            .frontmostApplication.bundleIdentifier;
    return [bundleIdentifier isEqualToString:@"com.openai.codex"];
}

- (NSScreen *)activeScreen {
    NSPoint cursor = NSEvent.mouseLocation;
    for (NSScreen *screen in NSScreen.screens) {
        if (NSPointInRect(cursor, screen.frame)) return screen;
    }
    return NSScreen.mainScreen ?: NSScreen.screens.firstObject;
}

- (NSScreen *)screenForFrame:(NSRect)frame {
    NSPoint center = NSMakePoint(NSMidX(frame), NSMidY(frame));
    for (NSScreen *screen in NSScreen.screens) {
        if (NSPointInRect(center, screen.frame)) return screen;
    }
    return [self activeScreen];
}

- (void)positionPanel {
    if (_positionInitialized) return;
    _positionInitialized = YES;

    if (_dockSide != HUDDockSideNone) {
        NSString *savedBallPosition =
            [NSUserDefaults.standardUserDefaults
                stringForKey:@"CodexQuotaGaugeBallOrigin"];
        NSRect candidate = _panel.frame;
        if (savedBallPosition.length > 0) {
            candidate.origin =
                NSPointFromString(savedBallPosition);
        } else {
            NSScreen *screen = [self activeScreen];
            if (screen) {
                NSRect visible = screen.visibleFrame;
                candidate.origin.x =
                    NSMaxX(visible) - NSWidth(candidate) - 20;
                candidate.origin.y =
                    NSMaxY(visible) - NSHeight(candidate) - 20;
            }
        }
        NSScreen *screen = [self screenForFrame:candidate];
        if (screen) {
            candidate = HUDBallFrameForDock(
                candidate,
                screen.visibleFrame,
                _dockSide,
                _hudScale
            );
            [_panel setFrame:candidate display:YES];
            [self updateChildPanelFrames];
            [self saveDockState];
            return;
        }
    }

    NSString *savedPosition =
        [NSUserDefaults.standardUserDefaults
            stringForKey:@"CodexQuotaResizableGaugeOrigin"];
    if (savedPosition.length > 0) {
        NSPoint savedOrigin = NSPointFromString(savedPosition);
        NSRect candidate = _panel.frame;
        candidate.origin = savedOrigin;
        for (NSScreen *screen in NSScreen.screens) {
            NSRect visible = screen.visibleFrame;
            if (NSWidth(NSIntersectionRect(candidate, visible)) >= 48 &&
                NSHeight(NSIntersectionRect(candidate, visible)) >= 24) {
                [_panel setFrameOrigin:savedOrigin];
                [self updateChildPanelFrames];
                return;
            }
        }
    }

    NSScreen *screen = [self activeScreen];
    if (!screen) return;
    NSRect visible = screen.visibleFrame;
    NSRect frame = _panel.frame;
    frame.origin.x = NSMaxX(visible) - NSWidth(frame) - 20;
    frame.origin.y = NSMaxY(visible) - NSHeight(frame) - 20;
    [_panel setFrameOrigin:frame.origin];
    [self updateChildPanelFrames];
}

- (void)constrainPanelToVisibleScreen {
    NSScreen *screen = [self activeScreen];
    if (!screen) return;
    NSRect visible = screen.visibleFrame;
    NSRect frame = _panel.frame;
    frame.origin.x = MIN(
        MAX(frame.origin.x, NSMinX(visible)),
        NSMaxX(visible) - NSWidth(frame)
    );
    frame.origin.y = MIN(
        MAX(frame.origin.y, NSMinY(visible)),
        NSMaxY(visible) - NSHeight(frame)
    );
    [_panel setFrameOrigin:frame.origin];
    [self updateChildPanelFrames];
}

- (void)savePanelPosition {
    if (_dockSide != HUDDockSideNone) return;
    NSRect frame = _panel.frame;
    NSPoint collapsedOrigin = NSMakePoint(
        frame.origin.x,
        NSMaxY(frame) - HUDBaseCollapsedHeight * _hudScale
    );
    NSString *position = NSStringFromPoint(collapsedOrigin);
    [NSUserDefaults.standardUserDefaults
        setObject:position
           forKey:@"CodexQuotaResizableGaugeOrigin"];
}

- (void)saveDockState {
    [NSUserDefaults.standardUserDefaults
        setInteger:_dockSide
            forKey:@"CodexQuotaGaugeDockSide"];
    if (_dockSide != HUDDockSideNone) {
        [NSUserDefaults.standardUserDefaults
            setObject:NSStringFromPoint(_panel.frame.origin)
               forKey:@"CodexQuotaGaugeBallOrigin"];
    }
}

- (void)applyDockPresentation {
    BOOL docked = _dockSide != HUDDockSideNone;
    _material.circular = docked;
    _statusBall.hidden = !docked;
    _quotaGauge.hidden = docked;
    if (docked) {
        _detailsExpanded = NO;
        _detailsContainer.hidden = YES;
        _resizeGrip.hidden = YES;
        _hoverRevealView.expanded = NO;
        _hoverRevealView.accessibilityLabel =
            @"额度状态球，拖离屏幕边缘恢复完整卡片";
    } else {
        _detailsContainer.hidden = !_detailsExpanded;
        _resizeGrip.hidden = !_detailsExpanded;
        _hoverRevealView.accessibilityLabel =
            @"鼠标悬停显示额度详情";
    }
}

- (void)dockToSide:(HUDDockSide)side
          onScreen:(NSScreen *)screen {
    if (side == HUDDockSideNone || !screen) return;
    if (_detailsExpanded) {
        [self setDetailsExpanded:NO];
    }
    if (_dockSide == HUDDockSideNone) {
        [self savePanelPosition];
    }
    NSRect sourceFrame = _panel.frame;
    _dockSide = side;
    [self applyDockPresentation];
    NSRect ballFrame = HUDBallFrameForDock(
        sourceFrame,
        screen.visibleFrame,
        side,
        _hudScale
    );
    [_panel setFrame:ballFrame display:YES];
    [self updateChildPanelFrames];
    [self saveDockState];
}

- (void)undockFromBallOnScreen:(NSScreen *)screen {
    if (_dockSide == HUDDockSideNone || !screen) return;
    NSRect ballFrame = _panel.frame;
    _dockSide = HUDDockSideNone;
    [self applyDockPresentation];

    NSRect frame = NSMakeRect(
        NSMidX(ballFrame) - HUDBaseWidth * _hudScale / 2,
        NSMidY(ballFrame) -
            HUDBaseCollapsedHeight * _hudScale / 2,
        HUDBaseWidth * _hudScale,
        HUDBaseCollapsedHeight * _hudScale
    );
    NSRect visible = screen.visibleFrame;
    frame.origin.x = MIN(
        MAX(frame.origin.x, NSMinX(visible)),
        NSMaxX(visible) - NSWidth(frame)
    );
    frame.origin.y = MIN(
        MAX(frame.origin.y, NSMinY(visible)),
        NSMaxY(visible) - NSHeight(frame)
    );
    [_panel setFrame:frame display:YES];
    [self updateChildPanelFrames];
    [self saveDockState];
    [self savePanelPosition];
}

- (void)finishPanelDrag {
    NSScreen *screen = [self activeScreen];
    if (!screen) return;
    HUDDockSide nearbySide =
        HUDDockSideNearFrame(_panel.frame, screen.visibleFrame);
    if (nearbySide != HUDDockSideNone) {
        [self dockToSide:nearbySide onScreen:screen];
    } else if (_dockSide != HUDDockSideNone) {
        [self undockFromBallOnScreen:screen];
    } else {
        [self constrainPanelToVisibleScreen];
        [self savePanelPosition];
    }
}

- (void)saveHUDScale {
    [NSUserDefaults.standardUserDefaults
        setObject:@(_hudScale)
           forKey:@"CodexQuotaGaugeScale"];
}

- (void)resizeHUDByDelta:(NSPoint)delta {
    CGFloat dominantDelta =
        fabs(delta.x) >= fabs(delta.y)
            ? delta.x
            : -delta.y;
    CGFloat nextScale =
        HUDClampedScale(
            _hudScale + dominantDelta / HUDBaseWidth
        );
    if (fabs(nextScale - _hudScale) < 0.0001) return;

    NSRect frame = _panel.frame;
    CGFloat topEdge = NSMaxY(frame);
    CGFloat leftEdge = NSMinX(frame);
    _hudScale = nextScale;
    frame.size.width = HUDBaseWidth * _hudScale;
    frame.size.height =
        (_detailsExpanded
            ? HUDBaseExpandedHeight
            : HUDBaseCollapsedHeight) * _hudScale;
    frame.origin.x = leftEdge;
    frame.origin.y = topEdge - NSHeight(frame);
    [_panel setFrame:frame display:YES];
    [self updateChildPanelFrames];
    [self saveHUDScale];
    [self savePanelPosition];
}

- (void)updateChildPanelFrames {
    NSRect frame = _panel.frame;
    [_hoverPanel setFrame:NSMakeRect(
        NSMinX(frame),
        NSMinY(frame),
        NSWidth(frame),
        NSHeight(frame)
    ) display:YES];
    [self layoutHUDSubviews];
    [_panel invalidateShadow];
}

- (void)layoutHUDSubviews {
    CGFloat width = NSWidth(_panel.frame);
    CGFloat height = NSHeight(_panel.frame);
    if (_dockSide != HUDDockSideNone) {
        _statusBall.frame =
            NSMakeRect(0, 0, width, height);
        [_material setNeedsLayout:YES];
        [_material setNeedsDisplay:YES];
        [_statusBall setNeedsDisplay:YES];
        return;
    }
    CGFloat collapsedHeight =
        HUDBaseCollapsedHeight * _hudScale;
    _quotaGauge.frame = NSMakeRect(
        0,
        height - collapsedHeight,
        width,
        collapsedHeight
    );

    CGFloat detailsHeight =
        MAX(0, height - collapsedHeight);
    _detailsContainer.frame =
        NSMakeRect(0, 0, width, detailsHeight);

    CGFloat rowX = 10 * _hudScale;
    CGFloat rowWidth = width - 20 * _hudScale;
    CGFloat rowHeight = 64 * _hudScale;
    _projectRow.frame =
        NSMakeRect(
            rowX,
            detailsHeight - 76 * _hudScale,
            rowWidth,
            rowHeight
        );
    _weeklyTotalRow.frame =
        NSMakeRect(
            rowX,
            detailsHeight - 148 * _hudScale,
            rowWidth,
            rowHeight
        );
    _lifetimeRow.frame =
        NSMakeRect(
            rowX,
            detailsHeight - 220 * _hudScale,
            rowWidth,
            rowHeight
        );
    CGFloat gripSize = 24 * _hudScale;
    _resizeGrip.frame =
        NSMakeRect(
            width - gripSize - 2 * _hudScale,
            2 * _hudScale,
            gripSize,
            gripSize
        );
    [_projectRow setNeedsLayout:YES];
    [_weeklyTotalRow setNeedsLayout:YES];
    [_lifetimeRow setNeedsLayout:YES];
    [_material setNeedsLayout:YES];
    [_material setNeedsDisplay:YES];
    [_quotaGauge setNeedsDisplay:YES];
    [_resizeGrip setNeedsDisplay:YES];
}

- (void)setDetailsExpanded:(BOOL)expanded {
    if (_dockSide != HUDDockSideNone) return;
    if (_detailsExpanded == expanded) return;
    _detailsExpanded = expanded;
    _detailsContainer.hidden = !expanded;
    _resizeGrip.hidden = !expanded;
    _hoverRevealView.expanded = expanded;
    _hoverRevealView.accessibilityLabel =
        expanded
            ? @"额度详情已展开，鼠标移出后收起"
            : @"鼠标悬停显示额度详情";

    NSRect frame = _panel.frame;
    CGFloat maximumHeight =
        HUDBaseExpandedHeight * _hudScale;
    NSScreen *screen = [self activeScreen];
    if (screen && expanded) {
        maximumHeight = NSHeight(screen.visibleFrame) - 40;
    }
    frame = HUDFrameForExpansion(
        frame,
        expanded,
        maximumHeight,
        _hudScale
    );
    [_panel setFrame:frame display:YES];
    [self constrainPanelToVisibleScreen];
    [self updateChildPanelFrames];
    [self savePanelPosition];
}

- (NSColor *)quotaAccentColor {
    if (!_quota) {
        return [NSColor colorWithWhite:1.0 alpha:0.34];
    }
    if (_quota.remainingPercent > 25) {
        return NSColor.systemGreenColor;
    }
    if (_quota.remainingPercent > 10) {
        return NSColor.systemOrangeColor;
    }
    return NSColor.systemRedColor;
}

- (void)updateVisibility {
    if ([self isCodexFrontmost]) {
        [self positionPanel];
        [_panel orderFront:nil];
    } else {
        [self setDetailsExpanded:NO];
        [_panel orderOut:nil];
    }
}

- (void)refresh {
    if (_refreshInFlight) return;
    _refreshInFlight = YES;

    BOOL shouldRefreshQuota =
        [NSDate.date timeIntervalSinceDate:_lastQuotaAttempt] >= 60;
    QuotaSnapshot *existingQuota = _quota;
    CodexDataSource *dataSource = _dataSource;

    dispatch_async(
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            QuotaSnapshot *freshQuota =
                shouldRefreshQuota
                    ? [dataSource loadQuota]
                    : existingQuota;
            QuotaSnapshot *effectiveQuota =
                freshQuota ?: existingQuota;
            NSDate *windowStart =
                effectiveQuota.resetsAt &&
                effectiveQuota.windowDurationMinutes > 0
                    ? [effectiveQuota.resetsAt
                        dateByAddingTimeInterval:
                            -(effectiveQuota.windowDurationMinutes * 60.0)]
                    : [NSDate dateWithTimeIntervalSinceNow:
                        -(7 * 24 * 60 * 60)];
            ProjectSnapshot *freshProject =
                [dataSource loadProjectSince:windowStart];

            dispatch_async(dispatch_get_main_queue(), ^{
                self->_refreshInFlight = NO;
                if (shouldRefreshQuota) {
                    self->_lastQuotaAttempt = NSDate.date;
                }
                if (freshQuota) self->_quota = freshQuota;
                if (freshProject) self->_project = freshProject;
                [self updateContent];
            });
        }
    );
}

- (void)updateContent {
    [_quotaGauge
        updateRemainingPercent:(_quota ? _quota.remainingPercent : 0)
                     available:(_quota != nil)
                   accentColor:[self quotaAccentColor]];
    [_statusBall
        updateRemainingPercent:(_quota ? _quota.remainingPercent : 0)
                     available:(_quota != nil)
                   accentColor:[self quotaAccentColor]];
    if (_project) {
        NSString *projectName =
            _project.name.length > 0 ? _project.name : @"当前项目";
        [_projectRow
            updateTitle:@"当前项目（本周）"
                  value:[NSString stringWithFormat:
                            @"%@ · %@",
                            projectName,
                            FormatTokens(_project.weeklyProjectTokens)]
               trailing:[NSString stringWithFormat:
                            @"%.1f%%",
                            ProjectShare(_project)]];
        [_weeklyTotalRow
            updateTitle:@"全部项目（本周）"
                  value:FormatTokens(_project.weeklyTotalTokens)
               trailing:nil];
    } else {
        [_projectRow updateTitle:@"当前项目（本周）"
                           value:@"正在读取…"
                        trailing:nil];
        [_weeklyTotalRow updateTitle:@"全部项目（本周）"
                               value:@"正在读取…"
                            trailing:nil];
    }
    [_lifetimeRow
        updateTitle:@"历史总消耗"
              value:(_quota && _quota.lifetimeTokens > 0
                    ? FormatLifetimeTokens(_quota.lifetimeTokens)
                    : @"--")
           trailing:nil];
    [self layoutHUDSubviews];
    [_material setNeedsDisplay:YES];
    [_hoverRevealView setNeedsDisplay:YES];
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) FloatingQuotaController *quotaController;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    if (!AXIsProcessTrusted() &&
        ![NSUserDefaults.standardUserDefaults
            boolForKey:@"CodexQuotaAccessibilityPromptedV1"]) {
        [NSUserDefaults.standardUserDefaults
            setBool:YES
             forKey:@"CodexQuotaAccessibilityPromptedV1"];
        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(0.8 * NSEC_PER_SEC)
            ),
            dispatch_get_main_queue(),
            ^{
                NSDictionary *options = @{
                    (__bridge NSString *)
                        kAXTrustedCheckOptionPrompt: @YES
                };
                AXIsProcessTrustedWithOptions(
                    (__bridge CFDictionaryRef)options
                );
            }
        );
    }
    self.quotaController = [FloatingQuotaController new];
}
@end

static int RunSelfTest(void) {
    @autoreleasepool {
        if (![FormatTokens(12000000) isEqualToString:@"1200万"]) {
            fprintf(stderr, "format test failed\n");
            return 1;
        }
        if (![FormatLifetimeTokens(100000000)
                isEqualToString:@"1.00亿"]) {
            fprintf(stderr, "lifetime format test failed\n");
            return 1;
        }
        NSString *repositoryTitle =
            @"[ArloYi/Codex-Token-Monitor]"
             "(https://github.com/ArloYi/Codex-Token-Monitor) "
             "加载这个项目";
        if (ThreadTitleMatchScore(
                @"Codex-Token-Monitor 加载这个项目",
                repositoryTitle
            ) < 100000 ||
            ThreadTitleMatchScore(
                @"关于 LinkedIn Growth 的一切…",
                @"关于 LinkedIn Growth 的一切，做一个可视化网址"
            ) < 80000 ||
            ThreadTitleMatchScore(
                @"完全不同的任务",
                repositoryTitle
            ) != 0) {
            fprintf(stderr, "active task title matching test failed\n");
            return 1;
        }
        CGFloat testScale = HUDDefaultScale;
        NSRect collapsedFrame =
            NSMakeRect(
                100,
                600,
                HUDBaseWidth * testScale,
                HUDBaseCollapsedHeight * testScale
            );
        NSRect expandedFrame =
            HUDFrameForExpansion(
                collapsedFrame,
                YES,
                1000,
                testScale
            );
        if (fabs(NSWidth(expandedFrame) -
                 HUDBaseWidth * testScale) > 0.001 ||
            fabs(NSHeight(expandedFrame) -
                 HUDBaseExpandedHeight * testScale) > 0.001 ||
            NSMaxY(expandedFrame) != NSMaxY(collapsedFrame) ||
            NSMinY(expandedFrame) >= NSMinY(collapsedFrame)) {
            fprintf(stderr, "downward expansion geometry test failed\n");
            return 1;
        }
        NSRect restoredFrame =
            HUDFrameForExpansion(
                expandedFrame,
                NO,
                1000,
                testScale
            );
        if (!NSEqualRects(restoredFrame, collapsedFrame)) {
            fprintf(stderr, "downward collapse geometry test failed\n");
            return 1;
        }
        if (HUDClampedScale(0.2) != HUDMinimumScale ||
            HUDClampedScale(2.0) != HUDMaximumScale ||
            HUDClampedScale(1.0) != 1.0) {
            fprintf(stderr, "HUD scale clamp test failed\n");
            return 1;
        }
        NSRect visibleFrame = NSMakeRect(0, 0, 1000, 800);
        NSRect interiorFrame =
            NSMakeRect(100, 100, 328, 85);
        if (HUDDockSideNearFrame(
                interiorFrame,
                visibleFrame
            ) != HUDDockSideNone ||
            HUDDockSideNearFrame(
                NSMakeRect(5, 120, 328, 85),
                visibleFrame
            ) != HUDDockSideLeft ||
            HUDDockSideNearFrame(
                NSMakeRect(667, 120, 328, 85),
                visibleFrame
            ) != HUDDockSideRight ||
            HUDDockSideNearFrame(
                NSMakeRect(120, 5, 328, 85),
                visibleFrame
            ) != HUDDockSideBottom ||
            HUDDockSideNearFrame(
                NSMakeRect(120, 710, 328, 85),
                visibleFrame
            ) != HUDDockSideTop) {
            fprintf(stderr, "HUD edge docking test failed\n");
            return 1;
        }
        NSRect rightBallFrame =
            HUDBallFrameForDock(
                interiorFrame,
                visibleFrame,
                HUDDockSideRight,
                testScale
            );
        if (fabs(NSWidth(rightBallFrame) -
                 HUDBaseBallDiameter * testScale) > 0.001 ||
            fabs(NSMaxX(rightBallFrame) -
                 (NSMaxX(visibleFrame) -
                  HUDDockMargin * testScale)) > 0.001) {
            fprintf(stderr, "HUD status ball geometry test failed\n");
            return 1;
        }
        NSRect surfaceBounds =
            NSMakeRect(
                0,
                0,
                HUDBaseWidth * testScale,
                HUDBaseCollapsedHeight * testScale
            );
        NSBezierPath *roundedSurface =
            [NSBezierPath bezierPathWithRoundedRect:
                NSInsetRect(surfaceBounds, 0.5, 0.5)
                                            xRadius:14.5 * testScale
                                            yRadius:14.5 * testScale];
        if ([roundedSurface containsPoint:NSMakePoint(0, 0)] ||
            ![roundedSurface containsPoint:
                NSMakePoint(
                    HUDBaseWidth * testScale / 2,
                    HUDBaseCollapsedHeight * testScale / 2
                )]) {
            fprintf(stderr, "rounded transparency test failed\n");
            return 1;
        }
        CodexDataSource *dataSource = [CodexDataSource new];
        NSDictionary *nullTokenEvent = @{
            @"timestamp": @"2026-07-22T00:00:00.000Z",
            @"payload": @{
                @"type": @"token_count",
                @"info": NSNull.null
            }
        };
        NSDictionary *validTokenEvent = @{
            @"payload": @{
                @"info": @{
                    @"total_token_usage": @{
                        @"total_tokens": @1234
                    }
                }
            }
        };
        if (TotalTokensFromRolloutEvent(nullTokenEvent) != nil ||
            [TotalTokensFromRolloutEvent(validTokenEvent)
                longLongValue] != 1234) {
            fprintf(stderr, "rollout null token test failed\n");
            return 1;
        }
        NSPipe *silentPipe = [NSPipe pipe];
        NSDate *timeoutStart = NSDate.date;
        NSData *unexpectedLine =
            [dataSource readLineFrom:silentPipe.fileHandleForReading
                             timeout:0.02];
        if (unexpectedLine ||
            [NSDate.date timeIntervalSinceDate:timeoutStart] > 0.5) {
            fprintf(stderr, "app-server timeout test failed\n");
            return 1;
        }
        CGFloat compactFont =
            AdaptiveFontSizeForText(
                @"额度剩余 60% ｜ 很长的示例项目名称项目本周消耗 "
                 "1200万 / 12000万 · 占比 10.0% ｜ "
                 "总消耗 Token 1.00亿",
                500
            );
        if (compactFont >= 12.0 || compactFont < 9.5) {
            fprintf(stderr, "adaptive font test failed\n");
            return 1;
        }

        __block NSInteger hoverTransitions = 0;
        __block BOOL hoverExpanded = NO;
        HoverRevealView *hoverView =
            [[HoverRevealView alloc]
                initWithFrame:NSMakeRect(
                    0,
                    0,
                    260,
                    HUDBaseCollapsedHeight * testScale
                )];
        hoverView.onHoverChanged = ^(BOOL expanded) {
            hoverTransitions += 1;
            hoverExpanded = expanded;
        };
        NSEvent *hoverEvent = [NSEvent
            mouseEventWithType:NSEventTypeMouseMoved
                      location:NSZeroPoint
                 modifierFlags:0
                     timestamp:0
                  windowNumber:0
                       context:nil
                   eventNumber:0
                    clickCount:0
                      pressure:0];
        [hoverView mouseEntered:hoverEvent];
        if (!hoverExpanded || hoverTransitions != 1) {
            fprintf(stderr, "hover expand test failed\n");
            return 1;
        }
        [hoverView mouseExited:hoverEvent];
        if (hoverExpanded || hoverTransitions != 2) {
            fprintf(stderr, "hover collapse test failed\n");
            return 1;
        }

        QuotaSnapshot *quota = [QuotaSnapshot new];
        quota.usedPercent = 40;
        quota.lifetimeTokens = 100000000;
        ProjectSnapshot *project = [ProjectSnapshot new];
        project.name = @"演示工具";
        project.weeklyProjectTokens = 12000000;
        project.weeklyTotalTokens = 120000000;
        NSString *actual = CompactStatusText(quota, project);
        NSString *expected =
            @"剩余 60% · 当前项目 1200万 · 本周 12000万";
        if (![actual isEqualToString:expected]) {
            fprintf(stderr, "compact summary test failed: %s\n",
                    actual.UTF8String);
            return 1;
        }
        if (fabs(ProjectShare(project) - 10.0) > 0.0001) {
            fprintf(stderr, "project share test failed\n");
            return 1;
        }
        NSString *floating = FloatingSummaryText(quota, project);
        NSString *expectedFloating =
            @"额度剩余 60% ｜ 演示工具项目本周消耗 "
             "1200万 / 12000万 · 占比 10.0% ｜ 总消耗 Token 1.00亿";
        if (![floating isEqualToString:expectedFloating]) {
            fprintf(stderr, "floating summary test failed: %s\n",
                    floating.UTF8String);
            return 1;
        }

        NSDictionary *selectionFixture = @{
            @"active-workspace-roots": @[@"/Projects/示例工具甲"],
            @"selected-project": @{@"projectId": @"quota"},
            @"local-projects": @{
                @"style": @{
                    @"name": @"示例工具甲",
                    @"rootPaths": @[@"/Projects/示例工具甲"]
                },
                @"quota": @{
                    @"name": @"示例工具乙",
                    @"rootPaths": @[@"/Projects/示例工具乙"]
                }
            }
        };
        NSDictionary *selected =
            SelectedLocalProject(selectionFixture);
        if (![selected[@"path"]
                isEqualToString:@"/Projects/示例工具乙"]) {
            fprintf(stderr,
                    "selected project priority test failed: %s\n",
                    [selected[@"path"] UTF8String]);
            return 1;
        }

        NSDictionary *nullSelectedFixture = @{
            @"active-workspace-roots": @[@"/Projects/示例工具甲"],
            @"selected-project": NSNull.null,
            @"local-projects": @{
                @"style": @{
                    @"name": @"示例工具甲",
                    @"rootPaths": @[@"/Projects/示例工具甲"]
                }
            }
        };
        NSDictionary *fallbackSelection =
            SelectedLocalProject(nullSelectedFixture);
        if (![fallbackSelection[@"path"]
                isEqualToString:@"/Projects/示例工具甲"]) {
            fprintf(stderr,
                    "null selected project fallback test failed\n");
            return 1;
        }

        NSDictionary *nullProjectFixture = @{
            @"active-workspace-roots": @[@"/Projects/示例工具甲"],
            @"selected-project": @{@"projectId": @"missing"},
            @"local-projects": @{
                @"missing": NSNull.null,
                @"style": @{
                    @"name": @"示例工具甲",
                    @"rootPaths": @[@"/Projects/示例工具甲"]
                }
            }
        };
        NSDictionary *nullProjectFallback =
            SelectedLocalProject(nullProjectFixture);
        if (![nullProjectFallback[@"path"]
                isEqualToString:@"/Projects/示例工具甲"]) {
            fprintf(stderr,
                    "null selected project value fallback test failed\n");
            return 1;
        }

        NSDictionary *nullRootsFixture = @{
            @"active-workspace-roots": NSNull.null,
            @"selected-project": NSNull.null,
            @"local-projects": @{}
        };
        if (SelectedLocalProject(nullRootsFixture) != nil) {
            fprintf(stderr, "null active roots test failed\n");
            return 1;
        }
        NSDictionary *activeThreadFixture = @{
            @"path": @"/Projects/示例工具乙/功能模块",
            @"title": @"正在编辑功能模块"
        };
        NSDictionary *activeSelection =
            ProjectSelectionForActiveThread(
                selectionFixture,
                activeThreadFixture
            );
        if (![activeSelection[@"path"]
                isEqualToString:@"/Projects/示例工具乙"] ||
            ![activeSelection[@"project"][@"name"]
                isEqualToString:@"示例工具乙"]) {
            fprintf(stderr,
                    "active thread project selection test failed\n");
            return 1;
        }
        NSDictionary *projectlessSelection =
            ProjectSelectionForActiveThread(
                nullRootsFixture,
                @{
                    @"path": @"/Projects/token-monitor",
                    @"title":
                        @"[Token Monitor](https://example.com) 加载项目"
                }
            );
        if (![projectlessSelection[@"path"]
                isEqualToString:@"/Projects/token-monitor"] ||
            ![projectlessSelection[@"project"][@"name"]
                isEqualToString:@"Token Monitor"] ||
            !PathBelongsToProject(
                @"/Projects/示例工具乙/功能模块",
                @"/Projects/示例工具乙"
            ) ||
            PathBelongsToProject(
                @"/Projects/示例工具乙扩展",
                @"/Projects/示例工具乙"
            )) {
            fprintf(stderr,
                    "active project path matching test failed\n");
            return 1;
        }

        printf("self-test passed\n");
        printf("sample=%s\n", actual.UTF8String);
        return 0;
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
            return RunSelfTest();
        }

        if (argc > 1 && strcmp(argv[1], "--snapshot") == 0) {
            CodexDataSource *dataSource = [CodexDataSource new];
            QuotaSnapshot *quota = [dataSource loadQuota];
            if (!quota) {
                fprintf(stderr, "quota unavailable\n");
                return 2;
            }
            NSDate *windowStart =
                quota.resetsAt && quota.windowDurationMinutes > 0
                    ? [quota.resetsAt dateByAddingTimeInterval:
                        -(quota.windowDurationMinutes * 60.0)]
                    : [NSDate dateWithTimeIntervalSinceNow:
                        -(7 * 24 * 60 * 60)];
            ProjectSnapshot *project =
                [dataSource loadProjectSince:windowStart];
            if (!project) {
                fprintf(stderr, "project unavailable\n");
                return 3;
            }
            printf("%s\n",
                FloatingSummaryText(quota, project).UTF8String);
            return 0;
        }

        if (argc > 1 &&
            strcmp(argv[1], "--project-snapshot") == 0) {
            CodexDataSource *dataSource = [CodexDataSource new];
            NSDate *windowStart =
                [NSDate dateWithTimeIntervalSinceNow:
                    -(7 * 24 * 60 * 60)];
            ProjectSnapshot *project =
                [dataSource loadProjectSince:windowStart];
            if (!project) {
                fprintf(stderr, "project unavailable\n");
                return 3;
            }
            printf(
                "%s\t%lld\t%lld\n",
                project.name.UTF8String,
                project.weeklyProjectTokens,
                project.weeklyTotalTokens
            );
            return 0;
        }

        NSApplication *application = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
