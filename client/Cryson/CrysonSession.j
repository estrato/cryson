/*
  Cryson
  
  Copyright 2011-2012 Björn Sperber (cryson@sperber.se)
  
  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at
  
  http://www.apache.org/licenses/LICENSE-2.0
  
  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
*/

@import "RequestHelper.j"
@import "CrysonEntity.j"
@import "CrysonSessionCache.j"
@import "CrysonSessionContext.j"
@import "CrysonSubSession.j"

/*!
  @class CrysonSession

  CrysonSession instances communicate with Cryson servers in order to fetch, track, commit and roll back graphs of entities backed by a database. Instances of CrysonSession should be obtained from a CrysonSessionFactory, rather than being directly instantiated.

  Every CrysonSession defines a session cache, where fetched entities are stored. The session cache is used to avoid unnecessary roundtrips to Cryson servers, as well as to guarantee that each fetched entity is represented by exactly one instance in the session.
*/
@implementation CrysonSession : CPObject
{
  CPString baseUrl;
  CrysonSessionCache rootEntities;
  CPMutableArray persistedEntities;
  CPMutableArray deletedEntities;
  RemoteService remoteService @accessors;
  CrysonDefinitionRepository crysonDefinitionRepository @accessors;
  id delegate @accessors;
  CPMutableDictionary loadOperationsByDelegate;
}

- (id)initWithBaseUrl:(CPString)aBaseUrl andDelegate:(id)aDelegate
{
  self = [super init];
  if (self) {
    baseUrl = aBaseUrl;
    remoteService = [RemoteService sharedInstance];
    crysonDefinitionRepository = [CrysonDefinitionRepository sharedInstance];
    rootEntities = [[CrysonSessionCache alloc] init];
    deletedEntities = [[CPMutableArray alloc] init];
    persistedEntities = [[CPMutableArray alloc] init];
    delegate = aDelegate;
    loadOperationsByDelegate = [CPMutableDictionary dictionary];
    nextTemporaryId = -1;
  }
  return self;
}

- (CPDictionary)findDefinitionForClass:(CLASS)klazz
{
  return [crysonDefinitionRepository findDefinitionForClass:klazz];
}

/*!
  Create a sub session

  @see CrysonSubSession
*/
- (CrysonSubSession)createSubSession
{
  return [[CrysonSubSession alloc] initWithSession:self];
}

/*!
  Evict/detach an entity from the session and from the session cache. After being detached, entities will no longer participate in commits and rollbacks.
*/
- (void)evict:(CrysonEntity)entity
{
  [persistedEntities removeObject:entity];
  [deletedEntities removeObject:entity];
  [rootEntities removeEntity:entity];
  [entity setSession:nil];
}

/*!
  Attach an entity to the session and to the session cache. After being attached, entities will participate in commits and rollbacks.
*/
- (void)attach:(CrysonEntity)entity
{
  [rootEntities addEntity:entity];
  [entity setSession:self];
}

/*!
  Schedule deletion of an entity for the next commit. A deleted entity is detached from the session, but will be reattached if the session is rolled back.
*/
- (void)delete:(CrysonEntity)entity
{
  if ([persistedEntities containsObject:entity]) {
    [self evict:entity];
  } else if (![persistedEntities containsObject:entity]) {
    [self evict:entity];
    [deletedEntities addObject:entity];
  }
}

/*!
  Schedules a new entity for persisting, assigning a temporary primary key if not explicitly set.
  Temporarily assigned primary keys will be replaced with actual keys on the next commit operation.
  Only persistent entities may be attached to sessions, either directly or through associations of entities already attached to a session.
  Consider using CrysonEntity#initWithSession: instead of calling this method directly.

  @see CrysonEntity#initWithSession:
*/
- (void)persist:(CrysonEntity)entity
{
  if ([entity id] == nil) {
    [entity setId:nextTemporaryId];
    nextTemporaryId = nextTemporaryId-1;
  }
  [persistedEntities addObject:entity];
  [self attach:entity];
}

/*!
  Boolean indicating whether the session contains entities with uncommitted changes. The dirty attribute is _not_ KVO compliant
  and will not broadcast state changes as individual entities change their respective dirty state.
*/
- (BOOL)dirty
{
  if ([persistedEntities count] > 0 || [deletedEntities count] > 0) {
    return YES;
  }
  var entityEnumerator = [rootEntities entityEnumerator];
  var entity;
  while((entity = [entityEnumerator nextObject]) != nil) {
    if ([entity dirty]) {
      return YES;
    }
  }
  return NO;
}

/*!
  Roll back any uncommitted changes to the entities in the session, by invoking their respective CrysonEntity#revert methods.
  A rollback is a purely client side operation and does not involve server side communication.

  @see CrysonEntity#revert
*/
- (void)rollback
{
  [self rollbackEntities:nil];
}

- (void)rollbackEntities:(CPArray)entitiesToRollback
{
  var deletedEntitiesEnumerator = [deletedEntities objectEnumerator];
  var deletedEntity;
  var rolledBackDeletedEntities = [];
  while((deletedEntity = [deletedEntitiesEnumerator nextObject]) != nil) {
    if (entitiesToRollback == nil || [entitiesToRollback containsObject:deletedEntity]) {
      [self attach:deletedEntity];
      [rolledBackDeletedEntities addObject:deletedEntity];
    }
  }
  [deletedEntities removeObjectsInArray:rolledBackDeletedEntities];

  var persistedEntitiesEnumerator = [[persistedEntities copy] objectEnumerator];
  var persistedEntity;
  while((persistedEntity = [persistedEntitiesEnumerator nextObject]) != nil) {
    if (entitiesToRollback == nil || [entitiesToRollback containsObject:persistedEntity]) {
      [self evict:persistedEntity];
      if ([persistedEntity id] < 0) {
        [persistedEntity setId:nil];
      }
    }
  }

  var entityEnumerator = [rootEntities entityEnumerator];
  var entity;
  while((entity = [entityEnumerator nextObject]) != nil) {
    if (entitiesToRollback == nil || [entitiesToRollback containsObject:entity]) {
      [entity revert];
    }
  }
}

@end

@implementation CrysonSession (Private)

- (CrysonEntity)findCachedByClass:(Class)entityClass andId:(int)id
{
  return [rootEntities findByClass:entityClass andId:id];
}

- (CPArray)materializeEntities:(CPArray)entityJSObjects
{
  var entities = [[CPMutableArray alloc] init];
  for(var ix = 0;ix < [entityJSObjects count];ix++) {
    var entityJSObject = [entityJSObjects objectAtIndex:ix];
    var entity = [self materializeEntity:entityJSObject];
    [entities addObject:entity];
  }
  return entities;
}

- (CrysonEntity)materializeEntity:(JSObject)entityJSObject
{
  var entityClass = CPClassFromString(entityJSObject.crysonEntityClass);
  var cachedEntity = [self findCachedByClass:entityClass andId:entityJSObject.id];
  if (cachedEntity) {
    return cachedEntity;
  }

  var entity = [[entityClass alloc] initWithJSObject:entityJSObject session:self];
  [rootEntities addEntity:entity];
  return entity;
}

@end

@implementation CrysonSession (Async)

/*!
  Given an entity class and a primary key, search first the session cache and, if necessary, a Cryson server for a matching entity. If the entity was found, the following delegate method will be called:
- - (void)crysonSession:(CrysonSession)aCrysonSession found:(CrysonEntity)anEntity byClass:(CLASS)anEntityClass

  Note: If the entity was found in the session cache, the delegate method will be called synchronously, otherwise it will be called asynchronously.

  If the entity was not found, the following delegate method will instead be called:
- - (void)crysonSession:(CrysonSession)aCrysonSession failedToFindByClass:(CLASS)anEntityClass andId:(int)anId error:(CrysonError)error

  By passing an array of key paths (e.g ["children", "children.toys"]) as the 'associationsToFetch' argument, it is possible to force eager fetching of associations that would otherwise have been lazily fetched.
  Note: 'associationsToFetch' will only be considered if the entity is fetched from a Cryson server and not already in the session cache.
*/
- (void)findByClass:(Class)entityClass andId:(int)id fetch:(CPArray)associationsToFetch delegate:(id)aDelegate
{
  var cachedEntity = [self findCachedByClass:entityClass andId:id];
  if (cachedEntity) {
    [aDelegate crysonSession:self found:cachedEntity byClass:entityClass];
  } else {
    [self fetchByClass:entityClass andId:id fetch:associationsToFetch delegate:aDelegate];
  }
}

/*!
  Same as CrysonSession#findByClass:andId:fetch:delegate:, but sends callback messages to the default delegate instead of an explicitly specified one.
@see CrysonSession#findByClass:andId:fetch:delegate:
*/
- (void)findByClass:(Class)entityClass andId:(int)id fetch:(CPArray)associationsToFetch
{
  [self findByClass:entityClass andId:id fetch:associationsToFetch delegate:delegate];
}

/*!
  Given an entity class and an array of primary keys, search first the session cache and, if necessary, a Cryson server for matching entities. If the entities were found, the following delegate method will be called:
- - (void)crysonSession:(CrysonSession)aCrysonSession found:(CPArray)someEntities byClass:(CLASS)anEntityClass andIds:(CPArray)someIds

  Note: If the entities were found in the session cache, the delegate method will be called synchronously, otherwise it will be called asynchronously.

  If the entities were not found, the following delegate method will instead be called:
- - (void)crysonSession:(CrysonSession)aCrysonSession failedToFindByClass:(CLASS)anEntityClass andIds:(CPArray)someIds error:(CrysonError)error

  By passing an array of key paths (e.g ["children", "children.toys"]) as the 'associationsToFetch' argument, it is possible to force eager fetching of associations that would otherwise have been lazily fetched.
  Note: 'associationsToFetch' will only be considered if the entity is fetched from a Cryson server and not already in the session cache.
*/
- (void)findByClass:(Class)entityClass andIds:(CPArray)ids fetch:(CPArray)associationsToFetch delegate:(id)aDelegate
{
  /* TODO: Check cache, like in the sync version
  var cachedEntity = [self findCachedByClass:entityClass andId:id];
  if (cachedEntity) {
    [aDelegate crysonSession:self found:cachedEntity byClass:entityClass];
  } else {
  */
    [self fetchByClass:entityClass andIds:ids fetch:associationsToFetch delegate:aDelegate];
    /*
  }
    */
}

/*!
  Same as CrysonSession#findByClass:andIds:fetch:delegate:, but sends callback messages to the default delegate instead of an explicitly specified one.
@see CrysonSession#findByClass:andIds:fetch:delegate:
*/
- (void)findByClass:(Class)entityClass andIds:(CPArray)ids fetch:(CPArray)associationsToFetch
{
  [self findByClass:entityClass andIds:ids fetch:associationsToFetch delegate:delegate];
}

/*!
  Refresh the state of a previously fetched entity, by re-reading it from a Cryson server. If an entity matching the specified class and primary key is not found in the session cache, this method is a no-op.

After a successful refresh, the following delegate method will be called:
- - (void)crysonSession:(CrysonSession)aCrysonSession refreshed:(CrysonEntity)anEntity

If the refresh operation fails, this delegate method will instead be called:
- - (void)crysonSession:(CrysonSession)aCrysonSession failedToRefresh:(CrysonEntity)anEntity error:(CrysonError)error

By passing an array of key paths (e.g ["children", "children.toys"]) as the 'associationsToFetch' argument, it is possible to force eager fetching of associations that would otherwise have been lazily fetched.
*/
- (void)refreshByClass:(Class)entityClass andId:(int)id fetch:(CPArray)associationsToFetch delegate:(id)aDelegate
{
  var cachedEntity = [self findCachedByClass:entityClass andId:id];
  if (cachedEntity) {
    [self refresh:cachedEntity fetch:associationsToFetch delegate:aDelegate];
  }
}

/*!
  Same as CrysonSession#refreshByClass:andId:fetch:delegate:, but sends callback messages to the default delegate instead of an explicitly specified one.
@see CrysonSession#refreshByClass:andId:fetch:delegate:
*/
- (void)refreshByClass:(Class)entityClass andId:(int)id fetch:(CPArray)associationsToFetch
{
  [self refreshByClass:entityClass andId:id fetch:associationsToFetch delegate:delegate];
}

/*!
  Given an entity class, query a Cryson server for all entities of that class. Upon successful completion, the following delegate method will be called:
- - (void)crysonSession:(CrysonSession)aCrysonSession foundAll:(CPArray)someEntities byClass:(CLASS)anEntityClass

  If a problem occurred, the following delegate method will instead be called:
- - (void)crysonSession:(CrysonSession)aCrysonSession failedToFindAllByClass:(CLASS)anEntityClass error:(CrysonError)error

By passing an array of key paths (e.g ["children", "children.toys"]) as the 'associationsToFetch' argument, it is possible to force eager fetching of associations that would otherwise have been lazily fetched.
*/
- (void)findAllByClass:(Class)entityClass fetch:(CPArray)associationsToFetch delegate:(id)aDelegate
{
  var url = baseUrl + "/" + entityClass.name + "/all" + "?fetch=" + [self _associationNamesToFetchString:associationsToFetch];
  var context = [CrysonSessionContext contextWithDelegate:aDelegate andEntityClass:entityClass];
  [self startLoadOperationForDelegate:aDelegate];
  [remoteService get:url
            delegate:self
           onSuccess:@selector(findAllByClassSucceeded:context:)
             onError:@selector(findAllByClassFailed:statusCode:context:)
             context:context];
}

/*!
  Same as CrysonSession#findAllByClass:fetch:delegate:, but sends callback messages to the default delegate instead of an explicitly specified one.
@see CrysonSession#findAllByClass:fetch:delegate:
*/
- (void)findAllByClass:(Class)entityClass fetch:(CPArray)associationsToFetch
{
  [self findAllByClass:entityClass fetch:associationsToFetch delegate:delegate];
}

/*!
  Given a named query and parameters, query a Cryson server for all entities matching the parameterized named query. Upon successful completion, the following delegate method will be called:
- - (void)crysonSession:(CrysonSession)aCrysonSession found:(CPArray)someEntities byNamedQuery:(CPString)aQueryName

  If a problem occurred, the following delegate method will instead be called:
- - (void)crysonSession:(CrysonSession)aCrysonSession failedToFindByNamedQuery:(CPString)aQueryName error:(CrysonError)error
*/
- (void)findByNamedQuery:(CPString)queryName withParameters:(CPDictionary)parameters delegate:(id)aDelegate
{
  var url = baseUrl + "/namedQuery/" + queryName + "/";
  var firstParameter = YES;
  var parameterNames = [parameters allKeys];
  for (var ix = 0;ix < [parameterNames count];ix++) {
    url += (firstParameter ? "?" : "&");
    firstParameter = NO;
    var parameterName = [parameterNames objectAtIndex:ix];
    url += parameterName + "=" + encodeURIComponent([parameters objectForKey:parameterName]);
  }
  var context = [CrysonSessionContext contextWithDelegate:aDelegate];
  [context setNamedQuery:queryName];
  [self startLoadOperationForDelegate:aDelegate];
  [remoteService get:url
            delegate:self
           onSuccess:@selector(findAllByNamedQuerySucceeded:context:)
             onError:@selector(findAllByNamedQueryFailed:statusCode:context:)
             context:context];
}

/*!
  Same as CrysonSession#findByNamedQuery:withParameters:delegate:, but sends callback messages to the default delegate instead of an explicitly specified one.
@see CrysonSession#findByNamedQuery:withParameters:delegate:
*/
- (void)findByNamedQuery:(CPString)queryName withParameters:(CPDictionary)parameters
{
  [self findByNamedQuery:queryName withParameters:parameters delegate:delegate];
}

/*!
  Given an entity instance, query a Cryson server for all entities with matching class and attributes. Upon successful completion, the following delegate method will be called:
- - (void)crysonSession:(CrysonSession)aCrysonSession found:(CPArray)someEntities byExample:(CrysonEntity)anExample

  If a problem occurred, the following delegate method will instead be called:
- - (void)crysonSession:(CrysonSession)aCrysonSession failedToFindByExample:(CrysonEntity)anExample error:(CrysonError)error

By passing an array of key paths (e.g ["children", "children.toys"]) as the 'associationsToFetch' argument, it is possible to force eager fetching of associations that would otherwise have been lazily fetched.
*/
- (void)findByExample:(CrysonEntity)exampleEntity fetch:(CPArray)associationsToFetch delegate:(id)aDelegate
{
  var entityClass = [exampleEntity class];
  var url = baseUrl + "/" + entityClass.name + "?example=" + encodeURIComponent(JSON.stringify([exampleEntity toJSObject])) + "&fetch=" + [self _associationNamesToFetchString:associationsToFetch];
  var context = [CrysonSessionContext contextWithDelegate:aDelegate andEntityClass:entityClass];
  [context setExample:exampleEntity];
  [self startLoadOperationForDelegate:aDelegate];
  [remoteService get:url
            delegate:self
           onSuccess:@selector(findAllByExampleSucceeded:context:)
             onError:@selector(findAllByExampleFailed:statusCode:context:)
             context:context];
}

/*!
  Same as CrysonSession#findByExample:fetch:delegate:, but sends callback messages to the default delegate instead of an explicitly specified one.
@see CrysonSession#findByExample:fetch:delegate:
*/
- (void)findByExample:(CrysonEntity)exampleEntity fetch:(CPArray)associationsToFetch
{
  [self findByExample:exampleEntity fetch:associationsToFetch delegate:delegate];
}

/*!
  Commit any uncommitted changes to the entities in the session. Upon successful completion, the following delegate method will be called:
- - (void)crysonSessionCommitted:(CrysonSession)aCrysonSession

Note: If no changes were committed, the delegate method will be called synchronously instead of asynchronously

If the commit failed, the following delegate method is instead called:
- - (void)crysonSession:(CrysonSession)aCrysonSession commitFailedWithError:(CrysonError)error
*/
- (void)commitWithDelegate:(id)aDelegate
{
  [self commitEntities:nil delegate:aDelegate];
}

/*!
  Same as CrysonSession#commitWithDelegate:, but sends callback messages to the default delegate instead of an explicitly specified one.
@see CrysonSession#commitWithDelegate:
*/
- (void)commit
{
  [self commitWithDelegate:delegate];
}

/*!
  Commit any uncommitted changes to the given entities. The same delegate methods are called as when using CrysonSession#commitWithDelegate:
@see CrysonSession#commitWithDelegate:
*/
- (void)commitEntities:(CPArray)entitiesToCommit delegate:(id)aDelegate
{
  var requestedDeletedEntities = [];
  var requestedDeletedEntityObjects = [];
  for(var ix = 0;ix < [deletedEntities count];ix++) {
    var entity = [deletedEntities objectAtIndex:ix];
    if (entitiesToCommit == nil || [entitiesToCommit containsObject:entity]) {
      var deletedEntityObject = [entity toJSObject];
      deletedEntityObject["crysonEntityClass"] = [entity className];
      [requestedDeletedEntities addObject:entity];
      [requestedDeletedEntityObjects addObject:deletedEntityObject];
    }
  }

  var requestedPersistedEntities = [];
  var requestedPersistedEntityObjects = [];
  for(var ix = 0;ix < [persistedEntities count];ix++) {
    var entity = [persistedEntities objectAtIndex:ix];
    if (entitiesToCommit == nil || [entitiesToCommit containsObject:entity]) {
      var persistedEntityObject = [entity toJSObject];
      persistedEntityObject["crysonEntityClass"] = [entity className];
      [requestedPersistedEntities addObject:entity];
      [requestedPersistedEntityObjects addObject:persistedEntityObject];
    }
  }

  var requestedUpdatedEntities = [];
  var requestedUpdatedEntityObjects = [];
  var enumerator = [rootEntities entityEnumerator];
  var entity;
  while((entity = [enumerator nextObject]) != nil) {
    if (entitiesToCommit == nil || [entitiesToCommit containsObject:entity]) {
      if ([entity dirty]) {
        if (![requestedDeletedEntities containsObject:entity] && ![requestedPersistedEntities containsObject:entity]) {
          var updatedEntityObject = [entity toJSObject];
          updatedEntityObject["crysonEntityClass"] = [entity className];
          [requestedUpdatedEntities addObject:entity];
          [requestedUpdatedEntityObjects addObject:updatedEntityObject];
        }
      }
    }
  }

  if ([requestedPersistedEntityObjects count] > 0 || [requestedDeletedEntityObjects count] > 0 || [requestedUpdatedEntityObjects count] > 0) {
    var commitRequest = {"persistedEntities":requestedPersistedEntityObjects,
                         "deletedEntities":requestedDeletedEntityObjects,
                         "updatedEntities":requestedUpdatedEntityObjects};

    var url = baseUrl + "/commit";
    var context = [CrysonSessionContext contextWithDelegate:aDelegate];
    [context setUpdatedEntities:requestedUpdatedEntities];
    [context setDeletedEntities:requestedDeletedEntities];
    [context setPersistedEntities:requestedPersistedEntities];
    [self startLoadOperationForDelegate:aDelegate];
    [remoteService post:commitRequest
                     to:url
               delegate:self
              onSuccess:@selector(commitSucceeded:context:)
                onError:@selector(commitFailed:statusCode:context:)
                context:context];
  } else {
    [aDelegate crysonSessionCommitted:self];
  }
}

/*!
  Same as CrysonSession#commitEntities:delegate:, but sends callback messages to the default delegate instead of an explicitly specified one.
@see CrysonSession#commitEntities:delegate:
*/
- (void)commitEntities:(CPArray)entitiesToCommit
{
  [self commitEntities:entitiesToCommit delegate:delegate];
}

@end

@implementation CrysonSession (AsyncPrivate)

- (void)fetchByClass:(Class)entityClass andId:(int)anId fetch:(CPArray)associationsToFetch delegate:(id)aDelegate
{
  var url = baseUrl + "/" + entityClass.name + "/" + anId + "?fetch=" + [self _associationNamesToFetchString:associationsToFetch];
  var context = [CrysonSessionContext contextWithDelegate:aDelegate andEntityClass:entityClass];
  [context setEntityId:anId];
  [self startLoadOperationForDelegate:aDelegate];
  [remoteService get:url
            delegate:self
           onSuccess:@selector(findByClassAndIdSucceeded:context:)
             onError:@selector(findByClassAndIdFailed:statusCode:context:)
             context:context];
}

- (void)fetchByClass:(Class)entityClass andIds:(CPArray)someIds fetch:(CPArray)associationsToFetch delegate:(id)aDelegate
{
  var url = baseUrl + "/" + entityClass.name + "/" + [someIds componentsJoinedByString:","] + "?fetch=" + [self _associationNamesToFetchString:associationsToFetch];
  var context = [CrysonSessionContext contextWithDelegate:aDelegate andEntityClass:entityClass];
  [context setEntityId:someIds];
  [self startLoadOperationForDelegate:aDelegate];
  [remoteService get:url
            delegate:self
           onSuccess:@selector(findByClassAndIdsSucceeded:context:)
             onError:@selector(findByClassAndIdsFailed:statusCode:context:)
             context:context];
}

- (CPString)_associationNamesToFetchString:(CPString)associationsToFetch
{
  if (associationsToFetch) {
    return [associationsToFetch componentsJoinedByString:","];
  }
  return "";
}

- (void)refresh:(CrysonEntity)crysonEntity fetch:(CPArray)associationsToFetch delegate:(id)aDelegate
{
  var url = baseUrl + "/" + [crysonEntity className] + "/" + [crysonEntity id] + "?fetch=" + [self _associationNamesToFetchString:associationsToFetch];
  var context = [CrysonSessionContext contextWithDelegate:aDelegate];
  [context setEntityToRefresh:crysonEntity];
  [self startLoadOperationForDelegate:aDelegate];
  [remoteService get:url
            delegate:self
           onSuccess:@selector(refreshSucceeded:context:)
             onError:@selector(refreshFailed:statusCode:context:)
             context:context];
}

@end

@implementation CrysonSession (AsyncCallbacks)

- (void)commitSucceeded:(JSObject)commitResult context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  [persistedEntities removeObjectsInArray:[context persistedEntities]];
  [self _replaceTemporaryIds:commitResult.replacedTemporaryIds forPersistedEntities:[context persistedEntities]];
  [self _refreshPersistedEntities:commitResult.persistedEntities];
  [[context updatedEntities] makeObjectsPerformSelector:@selector(virginize)];
  [deletedEntities removeObjectsInArray:[context deletedEntities]];
  [[context delegate] crysonSessionCommitted:self];
}

- (void)_replaceTemporaryIds:(JSObject)temporaryIdMapping forPersistedEntities:(CPArray)somePersistedEntities
{
  var persistedEntitiesEnumerator = [somePersistedEntities objectEnumerator];
  var persistedEntity = nil;
  while((persistedEntity = [persistedEntitiesEnumerator nextObject]) != nil) {
    [self evict:persistedEntity];
    [persistedEntity setId:temporaryIdMapping[[persistedEntity id]]];
    [self attach:persistedEntity];
  }
}

- (void)_refreshPersistedEntities:(CPArray)somePersistedEntities
{
  for(var ix = 0;ix < somePersistedEntities.length;ix++) {
    var persistedEntityJSObject = somePersistedEntities[ix];
    var entityClass = CPClassFromString(persistedEntityJSObject.crysonEntityClass);
    var entityId = persistedEntityJSObject.id;
    var persistedEntity = [self findCachedByClass:entityClass andId:entityId];
    [persistedEntity refreshWithJSObject:persistedEntityJSObject];
  }
}

- (void)commitFailed:(CPString)errorString statusCode:(CPNumber)statusCode context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  if ([[context delegate] respondsToSelector:@selector(crysonSession:commitFailedWithError:)]) {
    [[context delegate] crysonSession:self commitFailedWithError:[self _buildCrysonErrorWithRawMessage:errorString statusCode:statusCode]];
  }
}

- (void)findAllByClassSucceeded:(JSObject)entities context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  var entityClass = [context entityClass];
  var materializedEntities = [self materializeEntities:entities];
  [[context delegate] crysonSession:self foundAll:materializedEntities byClass:entityClass];
}

- (void)findAllByClassFailed:(CPString)errorString statusCode:(CPNumber)statusCode context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  if ([[context delegate] respondsToSelector:@selector(crysonSession:failedToFindAllByClass:error:)]) {
    [[context delegate] crysonSession:self failedToFindAllByClass:[context entityClass] error:[self _buildCrysonErrorWithRawMessage:errorString statusCode:statusCode]];
  }
}

- (void)findAllByNamedQuerySucceeded:(JSObject)entities context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  var namedQuery = [context namedQuery];
  var materializedEntities = [self materializeEntities:entities];
  [[context delegate] crysonSession:self found:materializedEntities byNamedQuery:namedQuery];
}

- (void)findAllByNamedQueryFailed:(CPString)errorString statusCode:(CPNumber)statusCode context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  if ([[context delegate] respondsToSelector:@selector(crysonSession:failedToFindByNamedQuery:error:)]) {
    [[context delegate] crysonSession:self failedToFindByNamedQuery:[context namedQuery] error:[self _buildCrysonErrorWithRawMessage:errorString statusCode:statusCode]];
  }
}

- (void)findAllByExampleSucceeded:(JSObject)entities context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  var entityClass = [context entityClass];
  var materializedEntities = [self materializeEntities:entities];
  [[context delegate] crysonSession:self found:materializedEntities byExample:[context example]];
}

- (void)findAllByExampleFailed:(CPString)errorString statusCode:(CPNumber)statusCode context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  if ([[context delegate] respondsToSelector:@selector(crysonSession:failedToFindByExample:error:)]) {
    [[context delegate] crysonSession:self failedToFindByExample:[context example] error:[self _buildCrysonErrorWithRawMessage:errorString statusCode:statusCode]];
  }
}

- (void)findByClassAndIdSucceeded:(JSObject)entity context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  var entityClass = [context entityClass];
  var materializedEntity = [self materializeEntity:entity];
  [[context delegate] crysonSession:self found:materializedEntity byClass:entityClass];
}

- (void)findByClassAndIdFailed:(CPString)errorString statusCode:(CPNumber)statusCode context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  if ([[context delegate] respondsToSelector:@selector(crysonSession:failedToFindByClass:andId:error:)]) {
    [[context delegate] crysonSession:self failedToFindByClass:[context entityClass] andId:[context entityId] error:[self _buildCrysonErrorWithRawMessage:errorString statusCode:statusCode]];
  }
}

- (void)findByClassAndIdsSucceeded:(CPArray)entities context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  var entityClass = [context entityClass];
  var entitiesArray = entities;
  if (!(entities instanceof Array)) {
    entitiesArray = [entitiesArray];
  }
  var materializedEntities = [self materializeEntities:entitiesArray];
  [[context delegate] crysonSession:self found:materializedEntities byClass:entityClass andIds:[context entityId]];
}

- (void)findByClassAndIdsFailed:(CPString)errorString statusCode:(CPNumber)statusCode context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  if ([[context delegate] respondsToSelector:@selector(crysonSession:failedToFindByClass:andIds:error:)]) {
    [[context delegate] crysonSession:self failedToFindByClass:[context entityClass] andIds:[context entityId] error:[self _buildCrysonErrorWithRawMessage:errorString statusCode:statusCode]];
  }
}

- (void)refreshSucceeded:(JSObject)entityJSObject context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  var entity = [context entityToRefresh];
  [entity refreshWithJSObject:entityJSObject];
  [[context delegate] crysonSession:self refreshed:entity];
}

- (void)refreshFailed:(CPString)errorString statusCode:(CPNumber)statusCode context:(CrysonSessionContext)context
{
  [self finishLoadOperationForDelegate:[context delegate]];
  if ([[context delegate] respondsToSelector:@selector(crysonSession:failedToRefresh:error:)]) {
    [[context delegate] crysonSession:self failedToRefresh:[context entityToRefresh] error:[self _buildCrysonErrorWithRawMessage:errorString statusCode:statusCode]];
  }
}

- (CrysonError)_buildCrysonErrorWithRawMessage:(CPString)aMessage statusCode:(CPNumber)statusCode
{
  if ([aMessage hasPrefix:@"{"]) {
    var jsonMessage = [aMessage objectFromJSON];
    return [CrysonError errorWithMessage:jsonMessage.message statusCode:statusCode validationFailures:[self _buildValidationFailures:jsonMessage.validationFailures]];
  } else {
    var errorMessage = "Unclassified error";
    if (statusCode == 0) {
      errorMessage = "Could not contact server";
    }
    return [CrysonError errorWithMessage:errorMessage statusCode:statusCode validationFailures:[]];
  }
}

- (CPArray)_buildValidationFailures:(CPArray)rawValidationFailures
{
  if (!rawValidationFailures) {
    return [];
  }
  
  var validationFailures = [];
  for(var ix = 0;ix < [rawValidationFailures count];ix++) {
    var rawValidationFailure = [rawValidationFailures objectAtIndex:ix];
    var entityClass = CPClassFromString(rawValidationFailure.entityClass);
    var entityId = rawValidationFailure.entityId;
    var entity = [self findCachedByClass:entityClass andId:entityId];
    var keyPath = rawValidationFailure.keyPath;
    var value = [entity valueForKeyPath:keyPath];
    [validationFailures addObject:[CrysonValidationFailure validationFailureWithEntity:entity keyPath:keyPath value:value message:rawValidationFailure.message]];
  }
  return validationFailures;
}

@end

@implementation CrysonSession (Sync)

/*!
  Given an entity class and a primary key, search first the session cache and, if necessary, a Cryson server for a matching entity. Returns the found entity, or nil if not found.

  Note: This operation performs a synchronous request to a Cryson server, blocking execution flow until a response from the server has been received.

  By passing an array of key paths (e.g ["children", "children.toys"]) as the 'associationsToFetch' argument, it is possible to force eager fetching of associations that would otherwise have been lazily fetched.
  Note: 'associationsToFetch' will only be considered if the entity is fetched from a Cryson server and not already in the session cache.
*/
- (CrysonEntity)findSyncByClass:(Class)entityClass andId:(int)id fetch:(CPArray)associationsToFetch
{
  var cachedEntity = [self findCachedByClass:entityClass andId:id];
  if (cachedEntity) {
    return cachedEntity;
  } else {
    var url = baseUrl + "/" + entityClass.name + "/" + id + "?fetch=" + [self _associationNamesToFetchString:associationsToFetch];
    [self startLoadOperationForDelegate:delegate];
    var entityJSObject = [RequestHelper syncGet:url];
    [self finishLoadOperationForDelegate:delegate];
    return [self materializeEntity:entityJSObject];
  }
}

/*!
  Given an entity class and an array of primary keys, search first the session cache and, if necessary, a Cryson server for matching entities. Returns the found entities as an array.

  Note: This operation performs a synchronous request to a Cryson server, blocking execution flow until a response from the server has been received.

  By passing an array of key paths (e.g ["children", "children.toys"]) as the 'associationsToFetch' argument, it is possible to force eager fetching of associations that would otherwise have been lazily fetched.
  Note: 'associationsToFetch' will only be considered if the entity is fetched from a Cryson server and not already in the session cache.
*/
- (CPArray)findSyncByClass:(Class)entityClass andIds:(CPArray)ids fetch:(CPArray)associationsToFetch
{
  var cachedEntities = [];
  var remainingEntityIds = [];

  for(var ix = 0;ix < [ids count];ix++) {
    var currentId = [ids objectAtIndex:ix];
    var cachedEntity = [self findCachedByClass:entityClass andId:currentId];
    if (cachedEntity) {
      [cachedEntities addObject:cachedEntity];
    } else {
      [remainingEntityIds addObject:currentId];
    }
  }

  var foundEntities = [];

  if ([remainingEntityIds count] == 1) {
    foundEntities = [[self findSyncByClass:entityClass andId:[remainingEntityIds objectAtIndex:0] fetch:associationsToFetch]];
  } else if ([remainingEntityIds count] > 1) {
    var url = baseUrl + "/" + entityClass.name + "/" + [remainingEntityIds componentsJoinedByString:","] + "?fetch=" + [self _associationNamesToFetchString:associationsToFetch];
    [self startLoadOperationForDelegate:delegate];
    var entityJSObjects = [RequestHelper syncGet:url];
    [self finishLoadOperationForDelegate:delegate];
    for(var ix = 0;ix < [entityJSObjects count];ix++) {
      [foundEntities addObject:[self materializeEntity:[entityJSObjects objectAtIndex:ix]]];
    }
  }

  return [cachedEntities arrayByAddingObjectsFromArray:foundEntities];
}

@end

@implementation CrysonSession (LoadingDelegateNotifications)

- (void)startLoadOperationForDelegate:(id)aDelegate
{
  var keyDelegate = delegate;
  if ([aDelegate respondsToSelector:@selector(crysonSessionDidStartLoadOperation:)]) {
    keyDelegate = aDelegate;
  }

  var oldLoadOperations = [loadOperationsByDelegate objectForKey:[keyDelegate UID]];
  [loadOperationsByDelegate setObject:((oldLoadOperations ? oldLoadOperations : 0) + 1) forKey:[keyDelegate UID]];
  if (!oldLoadOperations) {
    if ([keyDelegate respondsToSelector:@selector(crysonSessionDidStartLoadOperation:)]) {
      [keyDelegate crysonSessionDidStartLoadOperation:self];
    }
  }
}

- (void)finishLoadOperationForDelegate:(id)aDelegate
{
  var keyDelegate = delegate;
  if ([aDelegate respondsToSelector:@selector(crysonSessionDidFinishLoadOperation:)]) {
    keyDelegate = aDelegate;
  }

  var oldLoadOperations = [loadOperationsByDelegate objectForKey:[keyDelegate UID]];
  if (oldLoadOperations) {
    if (oldLoadOperations > 1) {
      [loadOperationsByDelegate setObject:(oldLoadOperations - 1) forKey:[keyDelegate UID]];
    } else {
      [loadOperationsByDelegate removeObjectForKey:[keyDelegate UID]];
      if ([keyDelegate respondsToSelector:@selector(crysonSessionDidFinishLoadOperation:)]) {
        [keyDelegate crysonSessionDidFinishLoadOperation:self];
      }
    }
  }
}

@end
