//
//  DiscPublishingFilesManager.mm
//  DiscPublishing
//
//  Created by Alessandro Volz on 2/26/10.
//  Copyright 2010 OsiriX Team. All rights reserved.
//

#import "DiscPublishingFilesManager.h"
#import "NSString+DiscPublishing.h"
#import <OsiriX Headers/Notifications.h>
#import <OsiriX Headers/ThreadsManager.h>
#import "NSUserDefaultsController+DiscPublishing.h"
#import "NSArray+DiscPublishing.h"
#import <OsiriX Headers/DicomImage.h>
#import <OsiriX Headers/DicomStudy.h>
#import <OsiriX Headers/BrowserController.h>
#import "DiscPublishingPatientDisc.h"
#import "DiscPublishingOptions.h"
#import <OsiriX Headers/NSThread+N2.h>


@interface DiscPublishingFilesManager (Private)

-(NSArray*)namesForStudies:(NSArray*)studies;
-(NSArray*)studiesForImages:(NSArray*)images;
-(void)spawnBurns;
-(void)spawnPatientBurn:(NSString*)patientUID;

@end


@implementation DiscPublishingFilesManager

@synthesize lastReceiveTime = _lastReceiveTime;
@synthesize patientsLastReceiveTimes = _patientsLastReceiveTimes;

-(id)init {
	self = [super init];
	
	[self setName:@"Stacking up incoming files for Disc Publishing..."];
	
	_files = [[NSMutableArray alloc] initWithCapacity:512];
	_filesLock = [[NSLock alloc] init];
	
	_patientsLastReceiveTimes = [[NSMutableDictionary alloc] initWithCapacity:512];
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(observeDatabaseAddition:) name:OsirixAddToDBCompleteNotification object:NULL];
	
	[self start];
	
	return self;
}

-(id)invalidate {
	[self cancel];
	while ([self isExecuting])
		[NSThread sleepForTimeInterval:0.01];
	return self;
}

-(void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self name:OsirixAddToDBCompleteNotification object:NULL];
	
	[_patientsLastReceiveTimes release];
	
	[_filesLock release];
	[_files release];
	self.lastReceiveTime = NULL;
	
	[super dealloc];
}

-(void)main {
	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
	
	while (![self isCancelled]) {
		NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
		
		while (![_filesLock tryLock])
			[NSThread sleepForTimeInterval:0.001];
		@try {
			if (_files.count) {
				// display thread info
				[[ThreadsManager defaultManager] performSelector:@selector(addThread:) withObject:self];
				
				// update thread status
				NSString* time = [NSString stringWithFormat:@"%@ since last receive", [NSString stringForTimeInterval:[[NSDate date] timeIntervalSinceDate:self.lastReceiveTime]]];
				if ([[NSUserDefaultsController sharedUserDefaultsController] discPublishingMode] == BurnModeArchiving) {
					self.status = [NSString stringWithFormat:@"Added files size is ZZZ, %@.", time];
				} else {
					self.status = [NSString stringWithFormat:@"Receiving images for %@, %@.", [[self namesForStudies:[self studiesForImages:_files]] componentsJoinedByCommasAndAnd], time];
				}
				
				// burn
				[self spawnBurns];
			} else {
				// hide thread info
				[[ThreadsManager defaultManager] performSelector:@selector(removeThread:) withObject:self];
			}
		} @catch (NSException* e) {
			NSLog(@"[DiscPublishingFilesManager main] error: %@", e);
		} @finally {
			[_filesLock unlock];
		}
		
		[NSThread sleepForTimeInterval:0.01];
		[pool release];
	}
	
	[pool release];
}

-(void)observeDatabaseAddition:(NSNotification*)notification {
	NSArray* addedImages = [[notification userInfo] objectForKey:OsirixAddToDBCompleteNotificationImagesArray];
	
	if (![[NSUserDefaultsController sharedUserDefaultsController] discPublishingIsActive])
		return;
	
	while (![_filesLock tryLock])
		[NSThread sleepForTimeInterval:0.001];
	@try {
		
		for (DicomImage* image in addedImages)
			if ([image managedObjectContext] == [[BrowserController currentBrowser] managedObjectContext])
				if (![_files containsObject:image])
					if (image.modality && ![image.modality isEqual:@"SR"])
						[_files addObject:image];
		
		NSDate* time = [NSDate date];
		self.lastReceiveTime = time;
		for (DicomImage* image in addedImages)
			[self.patientsLastReceiveTimes setObject:time forKey:[image valueForKeyPath:@"series.study.patientUID"]];
		
	} @catch (NSException* e) {
		NSLog(@"[DiscPublishingFilesManager observeDatabaseAddition:] error: %@", e);
	} @finally {
		[_filesLock unlock];
	}
}

-(NSArray*)namesForStudies:(NSArray*)studies {
	NSMutableArray* names = [[NSMutableArray alloc] initWithCapacity:studies.count];
	
	for (DicomStudy* study in studies) {
		NSString* name = [study valueForKeyPath:@"name"];
		if (![names containsObject:name])
			[names addObject:name];
	}
	
	return [names autorelease];
}

-(NSArray*)studiesForImages:(NSArray*)images {
	NSMutableArray* studies = [[NSMutableArray alloc] initWithCapacity:8];
	
	for (DicomImage* image in images) {
		DicomStudy* study = [image valueForKeyPath:@"series.study"];
		if (![studies containsObject:study])
			[studies addObject:study];
	}
	
	return [studies autorelease];
}

-(void)spawnBurns {
	NSTimeInterval burnDelay = [[NSUserDefaultsController sharedUserDefaultsController] discPublishingPatientModeDelay];
	NSMutableArray* patientsToBurn = [[NSMutableArray alloc] initWithCapacity:self.patientsLastReceiveTimes.count];
	
	for (NSString* patientUID in self.patientsLastReceiveTimes) {
		NSDate* time = [self.patientsLastReceiveTimes objectForKey:patientUID];
		if ([[NSDate date] timeIntervalSinceDate:time] >= burnDelay)
			[patientsToBurn addObject:patientUID];
	}
	
	for (NSString* patientUID in patientsToBurn)
		[self spawnPatientBurn:patientUID];
	
	[patientsToBurn release];
}

-(void)spawnPatientBurn:(NSString*)patientUID {
	NSMutableArray* files = [[NSMutableArray alloc] initWithCapacity:512];
	
	for (DicomImage* file in _files)
		if ([[file valueForKeyPath:@"series.study.patientUID"] isEqual:patientUID])
			[files addObject:file];
	[_files removeObjectsInArray:files];
	[self.patientsLastReceiveTimes removeObjectForKey:patientUID];

//	NSLog(@"removed %d files, %d left", files.count, _files.count);
	
	if (files.count) {
		DiscPublishingPatientDisc* dppd = [[[DiscPublishingPatientDisc alloc] initWithFiles:files options:[[NSUserDefaultsController sharedUserDefaultsController] discPublishingPatientModeOptions]] autorelease];
		[[ThreadsManager defaultManager] addThreadAndStart:dppd];
	}
	
	[files release];
}

@end























