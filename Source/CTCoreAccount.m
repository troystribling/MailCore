/*
 * MailCore
 *
 * Copyright (C) 2007 - Matt Ronge
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of the MailCore project nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHORS AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#import "CTCoreAccount.h"
#import "CTCoreFolder.h"
#import "MailCoreTypes.h"
#import "MailCoreUtilities.h"

@interface CTCoreAccount ()
@end


@implementation CTCoreAccount
@synthesize lastError;

- (id)init {
    self = [super init];
    if (self) {
        connected = NO;
        myStorage = mailstorage_new(NULL);
        assert(myStorage != NULL);
    }
    return self;
}


- (void)dealloc {
    mailstorage_disconnect(myStorage);
    mailstorage_free(myStorage);
    self.lastError = nil;
    [super dealloc];
}

- (NSError *)lastError {
    return lastError;
}

- (BOOL)isConnected {
    return connected;
}

- (BOOL)connectToServer:(NSString *)server port:(int)port
        connectionType:(int)conType authType:(int)authType
        login:(NSString *)login password:(NSString *)password {
    int err = 0;
    int imap_cached = 0;

    const char* auth_type_to_pass = NULL;
    if(authType == IMAP_AUTH_TYPE_SASL_CRAM_MD5) {
        auth_type_to_pass = "CRAM-MD5";
    }

    err = imap_mailstorage_init_sasl(myStorage,
                                     (char *)[server cStringUsingEncoding:NSUTF8StringEncoding],
                                     (uint16_t)port, NULL,
                                     conType,
                                     auth_type_to_pass,
                                     NULL,
                                     NULL, NULL,
                                     (char *)[login cStringUsingEncoding:NSUTF8StringEncoding], (char *)[login cStringUsingEncoding:NSUTF8StringEncoding],
                                     (char *)[password cStringUsingEncoding:NSUTF8StringEncoding], NULL,
                                     imap_cached, NULL);

    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }

    err = mailstorage_connect(myStorage);
    if (err == MAIL_ERROR_LOGIN) {
        self.lastError = MailCoreCreateError(err, @"Invalid username or password");
        return NO;
    } else if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    connected = YES;
    return YES;
}

- (BOOL)idle {
    int err = mailimap_idle([self session]);

    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    return YES;
}

- (NSString*)read {
    char * buf = mailimap_read_line([self session]);

    if (buf == NULL) {
        return nil;
    }

    return [NSString stringWithCString:buf encoding:NSUTF8StringEncoding];
}

- (BOOL)done {
    int err = mailimap_idle_done([self session]);

    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    return YES;
}

- (void)disconnect {
    if (connected) {
        connected = NO;
        mailstorage_disconnect(myStorage);
    }
}

- (CTCoreFolder *)folderWithPath:(NSString *)path {
    CTCoreFolder *folder = [[CTCoreFolder alloc] initWithPath:path inAccount:self];
    return [folder autorelease];
}


- (mailimap *)session {
    struct imap_cached_session_state_data * cached_data;
    struct imap_session_state_data * data;
    mailsession *session;

    session = myStorage->sto_session;
    if(session == nil) {
        return nil;
    }
    if (strcasecmp(session->sess_driver->sess_name, "imap-cached") == 0) {
        cached_data = session->sess_data;
        session = cached_data->imap_ancestor;
    }

    data = session->sess_data;
    return data->imap_session;
}


- (struct mailstorage *)storageStruct {
    return myStorage;
}


- (NSSet *)subscribedFolders {
    struct mailimap_mailbox_list * mailboxStruct;
    clist *subscribedList;
    clistiter *cur;

    NSString *mailboxNameObject;
    char *mailboxName;
    int err;

    NSMutableSet *subscribedFolders = [NSMutableSet set];

    //Fill the subscribed folder array
    err = mailimap_lsub([self session], "", "*", &subscribedList);
    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return nil;
    }
    for(cur = clist_begin(subscribedList); cur != NULL; cur = cur->next) {
        mailboxStruct = cur->data;
        struct mailimap_mbx_list_flags *flags = mailboxStruct->mb_flag;
        BOOL selectable = YES;
        if (flags) {
            selectable = !(flags->mbf_type==MAILIMAP_MBX_LIST_FLAGS_SFLAG && flags->mbf_sflag==MAILIMAP_MBX_LIST_SFLAG_NOSELECT);
        }
        
        if (selectable) {
            mailboxName = mailboxStruct->mb_name;
            mailboxNameObject = [NSString stringWithCString:mailboxName encoding:NSUTF8StringEncoding];
            
            // Replace the delimiter with /, in MailCore we always use / as the delimiter
            // One potential problem is if the user has a / in their folder name....
            if (mailboxStruct->mb_delimiter) {
                NSString *delimiter = [NSString stringWithFormat:@"%c", mailboxStruct->mb_delimiter];
                mailboxNameObject = [mailboxNameObject stringByReplacingOccurrencesOfString:delimiter withString:@"/"];
                
            }
            [subscribedFolders addObject:mailboxNameObject];
        }
    }
    mailimap_list_result_free(subscribedList);
    return subscribedFolders;
}

- (NSSet *)allFolders {
    struct mailimap_mailbox_list * mailboxStruct;
    clist *allList;
    clistiter *cur;

    NSString *mailboxNameObject;
    char *mailboxName;
    int err;

    NSMutableSet *allFolders = [NSMutableSet set];

    //Now, fill the all folders array
    //TODO Fix this so it doesn't use *
    err = mailimap_list([self session], "", "*", &allList);
    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return nil;
    }
    for(cur = clist_begin(allList); cur != NULL; cur = cur->next)
    {
        mailboxStruct = cur->data;
        struct mailimap_mbx_list_flags *flags = mailboxStruct->mb_flag;
        BOOL selectable = YES;
        if (flags) {
            selectable = !(flags->mbf_type==MAILIMAP_MBX_LIST_FLAGS_SFLAG && flags->mbf_sflag==MAILIMAP_MBX_LIST_SFLAG_NOSELECT);
        }
        if (selectable) {
            mailboxName = mailboxStruct->mb_name;
            mailboxNameObject = [NSString stringWithCString:mailboxName encoding:NSUTF8StringEncoding];
            
            // Replace the delimiter with /, in MailCore we always use / as the delimiter
            // One potential problem is if the user has a / in their folder name....
            if (mailboxStruct->mb_delimiter) {
                NSString *delimiter = [NSString stringWithFormat:@"%c", mailboxStruct->mb_delimiter];
                mailboxNameObject = [mailboxNameObject stringByReplacingOccurrencesOfString:delimiter withString:@"/"];
                
            }
            [allFolders addObject:mailboxNameObject];
        }
    }
    mailimap_list_result_free(allList);
    return allFolders;
}
@end
