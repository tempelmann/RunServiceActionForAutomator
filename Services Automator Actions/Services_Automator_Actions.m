//
//  Services_Automator_Actions.m
//  Services Automator Actions
//
//  Created by Thomas Tempelmann on 06.07.15.
//  No rights reserved, use as you like.
//

#import "Services_Automator_Actions.h"
#import <OSAKit/OSAKit.h>

const int InputTypeAuto = 0;
const int InputTypeNone = 1;
const int InputTypeText = 2;
const int InputTypeFiles = 3;

const int OutputTypeAuto = 0;
const int OutputTypeText = 1;
const int OutputTypeFiles = 2;

@implementation Services_Automator_Actions

- (instancetype)initWithDefinition:(NSDictionary *)dict fromArchive:(BOOL)archived
{
	//NSLog(@"%s dict: %@", __FUNCTION__, dict);
	self = [super initWithDefinition:dict fromArchive:archived];
	if (self) {
		// We're using Auto Layout - we need to do this here to avoid a warning in the Console log:
		self.view.translatesAutoresizingMaskIntoConstraints = NO;
	}
	return self;
}

- (id)runWithInput:(NSArray*)input error:(NSError * _Nullable *)errorOut
{
	//NSLog(@"%s parms: %@", __FUNCTION__, self.parameters);

	NSString *serviceName = self.parameters[@"serviceName"];
	int inputType = [(NSNumber*)self.parameters[@"inputType"] intValue];
	int outputType = [(NSNumber*)self.parameters[@"outputType"] intValue];
	
	NSPasteboard *pboard = [NSPasteboard pasteboardWithUniqueName];
	
	NSMutableArray *fileURLs = [NSMutableArray array];
	NSMutableArray *plainTexts = [NSMutableArray array];
	NSMutableArray *richTexts = [NSMutableArray array];
	
	if (!self.ignoresInput) {
		// Check every item in the clipboard
		for (id item in input) {
		
			if ([item isKindOfClass:[NSAttributedString class]]) {
				// It's a rich text item
				NSLog(@"Got NSAttributedString: %@", item);
				NSAttributedString *text = item;
				[richTexts addObject:text];

			} else if ([item isKindOfClass:[NSString class]]) {
				// It's a plain text item
				NSString *str = item;
				NSLog(@"Got NSString: %@", str);
				[plainTexts addObject:str];
				NSString *firstChar = [str substringToIndex:1];
				if ([firstChar isEqualToString:@"/"]) {
					// could be a file path - check if it's valid and if the path actually exists
					@try {
						NSURL *url = [NSURL fileURLWithPath:str];
						if (url && url.isFileURL && [url checkResourceIsReachableAndReturnError:NULL]) {
							[fileURLs addObject:url];
						}
					}
					@catch (NSException *exception) {
						// ignore
					}
				}

			} else {
				// I'd expect fo find other types as well, such as URLs, but nothing else came so far.
				NSLog(@"Unsupported input type: %s", object_getClassName(item));

			}
		}
	}
	
	//
	// Now, depending on the collected data and the "Input Type" settings, prepare the Pasteboard contents for the Service
	//
	if (inputType == InputTypeNone || self.ignoresInput) {
		// Send empty pasteboard to Service

	} else if ((inputType == InputTypeFiles) || ((inputType == InputTypeAuto) && richTexts.count == 0 && fileURLs.count > 0 && fileURLs.count == plainTexts.count)) {
		// Handle these automatically as file refs if all the input items are plain text and contain a valid path.
		// Write the URL(s) to the pasteboard
		//NSLog(@"Adding files: %@", fileURLs);
		if (![pboard writeObjects:fileURLs]) {
			NSLog(@"Error: Could not set fileURLs");
		}
		// Write a plain text with all paths (separated by EOLn) to the pasteboard.
		// Note: This is a little different from the Finder, who doesn't include full paths but only the file names. Not sure if this matters, though.
		NSString *txt = [plainTexts componentsJoinedByString:@"\n"];
		//NSLog(@"Adding texts: %@", txt);
		[pboard setString:txt forType:NSStringPboardType];
		
	} else if (richTexts.count > 0) {
		// Send rich text to Service
		//NSLog(@"Adding rich texts: %@", richTexts);
		if (![pboard writeObjects:richTexts]) {
			NSLog(@"Error: Could not set richTexts");
		}
	} else if (plainTexts.count > 0) {
		// Send plain text to Service
		//NSLog(@"Adding texts: %@", plainTexts);
		if (![pboard writeObjects:plainTexts]) {
			NSLog(@"Error: Could not set plainTexts");
		}
	}
	
	// Remember the change count to see if the Pasteboard contents gets changed by the Service
	NSInteger pbChangeCount = pboard.changeCount;
	
	//
	// Invoke the Service now
	//
	BOOL done = NSPerformService (serviceName, pboard);
	if (!done) {
		// Service didn't get invoked. Let's report this back
		*errorOut = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:
			@{NSLocalizedDescriptionKey:
				[NSString stringWithFormat:@"The Service '%@' could not be invoked. Check its name and input type.", serviceName]
			}];
		return NULL;
	}

	if (pbChangeCount == pboard.changeCount) {
		// Service did not produce a result
		NSLog(@"No returns from Service");
		return NULL;
	}
	
	//
	// Parse pasteboard contents returned by the service.
	//
	
	if (pboard.pasteboardItems.count == 0) {
		return @"";
	}

	// Try to extract file URLs
	if (outputType == OutputTypeAuto || outputType == OutputTypeFiles) {
		NSArray *urls = [pboard readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@1}];
		if (urls) {
			if ((outputType == OutputTypeFiles && urls.count > 0) || urls.count == pboard.pasteboardItems.count) {
				// We need to convert the URLs to paths
				NSMutableArray *filePaths = [NSMutableArray array];
				for (NSURL *url in urls) {
					[filePaths addObject:[url path]];
				}
				NSLog(@"Result URLs as paths: %@", filePaths);
				return urls;
			}
		}
	}

	// Otherwise we expect to find text in the Service's result.
	NSArray *result = [pboard readObjectsForClasses:@[[NSAttributedString class], [NSString class]] options:nil];
	
	if (outputType == OutputTypeFiles) {
		// Check the results for file paths
		NSMutableArray *filePaths = [NSMutableArray array];
		@try {
			// if we have multiple items, each of them should be a path. Otherwise it might be LF-delimited lines of paths.
			NSArray *candidates;
			if (result.count > 1) {
				candidates = result;
			} else {
				id singleText = result[0];
				if ([singleText isKindOfClass:[NSAttributedString class]]) {
					// extract plain text
					singleText = [(NSAttributedString*)singleText string];
				}
				candidates = [singleText componentsSeparatedByString:@"\n"];
			}
			for (id item in candidates) {
				if (![item isKindOfClass:[NSString class]]) {
					break;	// any non-path item stops the search
				}
				NSURL *url = [NSURL fileURLWithPath:item];
				if (url && url.isFileURL && [url checkResourceIsReachableAndReturnError:NULL]) {
					[filePaths addObject:item];
				} else {
					break;	// any non-path item stops the search
				}
			}
			if (filePaths.count == candidates.count) {
				// all the items are file paths
				NSLog(@"Result paths: %@", filePaths);
				return filePaths;
			}
		}
		@catch (NSException *exception) {
			// any non-path item stops the search for file paths
		}
	}
	
	NSLog(@"Result text: %@", result);
	return result;
}

@end
