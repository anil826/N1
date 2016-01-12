fs = require 'fs'
path = require 'path'
Reflux = require 'reflux'
Rx = require 'rx-lite'
Actions = require '../actions'
Contact = require '../models/contact'
Utils = require '../models/utils'
NylasStore = require 'nylas-store'
RegExpUtils = require '../../regexp-utils'
DatabaseStore = require './database-store'
AccountStore = require './account-store'
ContactRankingStore = require './contact-ranking-store'
_ = require 'underscore'

WindowBridge = require '../../window-bridge'

###
Public: ContactStore maintains an in-memory cache of the user's address
book, making it easy to build autocompletion functionality and resolve
the names associated with email addresses.

## Listening for Changes

The ContactStore monitors the {DatabaseStore} for changes to {Contact} models
and triggers when contacts have changed, allowing your stores and components
to refresh data based on the ContactStore.

```coffee
@unsubscribe = ContactStore.listen(@_onContactsChanged, @)

_onContactsChanged: ->
  # refresh your contact results
```

Section: Stores
###
class ContactStore extends NylasStore

  constructor: ->
    if NylasEnv.isMainWindow() or NylasEnv.inSpecMode()
      @_contactCache = {}
      @listenTo ContactRankingStore, @_sortContactsCacheWithRankings
      @_registerObservables()
      @_refreshCache()

  _registerObservables: =>
    # TODO I'm a bit worried about how big a cache this might be
    @disposable?.dispose()
    query = DatabaseStore.findAll(Contact)
    @_disposable = Rx.Observable.fromQuery(query).subscribe(@_onContactsChanged)

  _onContactsChanged: (contacts) =>
    @_refreshCache(contacts)

  # Public: Search the user's contact list for the given search term.
  # This method compares the `search` string against each Contact's
  # `name` and `email`.
  #
  # - `search` {String} A search phrase, such as `ben@n` or `Ben G`
  # - `options` (optional) {Object} If you will only be displaying a few results,
  #   you should pass a limit value. {::searchContacts} will return as soon
  #   as `limit` matches have been found.
  #
  # Returns an {Array} of matching {Contact} models
  #
  # TODO pass accountId in all the appropriate places
  searchContacts: (search, options={}) =>
    {limit, noPromise, accountId} = options
    if not NylasEnv.isMainWindow()
      if noPromise
        throw new Error("We search Contacts in the Main window, which makes it impossible for this to be a noPromise method from this window")
      # Returns a promise that resolves to the value of searchContacts
      return WindowBridge.runInMainWindow("ContactStore", "searchContacts", [search, options])

    if not search or search.length is 0
      if noPromise
        return []
      else
        return Promise.resolve([])

    limit ?= 5
    limit = Math.max(limit, 0)
    search = search.toLowerCase()

    matchFunction = (contact) ->
      # For the time being, we never return contacts that are missing
      # email addresses
      return false unless contact.email
      # - email (bengotow@gmail.com)
      # - email domain (test@bengotow.com)
      # - name parts (Ben, Go)
      # - name full (Ben Gotow)
      #   (necessary so user can type more than first name ie: "Ben Go")
      if contact.email
        i = contact.email.toLowerCase().indexOf(search)
        return true if i is 0 or i is contact.email.indexOf('@') + 1
      if contact.name
        return true if contact.name.toLowerCase().indexOf(search) is 0

      name = contact.name?.toLowerCase() ? ""
      for namePart in name.split(/\s/)
        return true if namePart.indexOf(search) is 0
      false

    matches = []
    contacts = if accountId?
      @_contactCache[accountId]
    else
      _.flatten(_.values(@_contactCache))

    for contact in contacts
      if matchFunction(contact)
        matches.push(contact)
        if matches.length is limit
          break

    if noPromise
      return matches
    else
      return Promise.resolve(matches)

  # Public: Returns true if the contact provided is a {Contact} instance and
  # contains a properly formatted email address.
  #
  isValidContact: (contact) =>
    return false unless contact instanceof Contact
    return false unless contact.email

    # The email regexp must match the /entire/ email address
    result = RegExpUtils.emailRegex().exec(contact.email)
    if result and result instanceof Array
      return result[0] is contact.email
    else return false

  parseContactsInString: (contactString, options={}) =>
    {skipNameLookup, accountId} = options
    if not NylasEnv.isMainWindow()
      # Returns a promise that resolves to the value of searchContacts
      return WindowBridge.runInMainWindow("ContactStore", "parseContactsInString", [contactString, options])

    detected = []
    emailRegex = RegExpUtils.emailRegex()
    lastMatchEnd = 0

    while (match = emailRegex.exec(contactString))
      email = match[0]
      name = null

      startsWithQuote = email[0] in ['\'','"']
      hasTrailingQuote = contactString[match.index+email.length] in ['\'','"']
      if startsWithQuote and hasTrailingQuote
        email = email[1..-1]

      hasLeadingParen  = contactString[match.index-1] in ['(','<']
      hasTrailingParen = contactString[match.index+email.length] in [')','>']

      if hasLeadingParen and hasTrailingParen
        nameStart = lastMatchEnd
        for char in [',', '\n', '\r']
          i = contactString.lastIndexOf(char, match.index)
          nameStart = i+1 if i+1 > nameStart
        name = contactString.substr(nameStart, match.index - 1 - nameStart).trim()

      if (not name or name.length is 0) and not skipNameLookup
        # Look to see if we can find a name for this email address in the ContactStore.
        # Otherwise, just populate the name with the email address.
        existing = @searchContacts(email, {accountId: accountId, limit:1, noPromise: true})[0]
        if existing and existing.name
          name = existing.name
        else
          name = email

      # The "nameStart" for the next match must begin after lastMatchEnd
      lastMatchEnd = match.index+email.length
      if hasTrailingParen
        lastMatchEnd += 1

      if name
        # If the first and last character of the name are quotation marks, remove them
        [first,...,last] = name
        if first in ['"', "'"] and last in ['"', "'"]
          name = name[1...-1]

      detected.push(new Contact({email, name}))

    return Promise.resolve(detected)

  __refreshCache: (contacts) =>
    return unless contacts
    contacts.forEach (contact) =>
      @_contactCache[contact.accountId] ?= []
      @_contactCache[contact.accountId].push(contact)
    @_sortContactsCacheWithRankings()
    @trigger()
    return true

  _refreshCache: _.debounce(ContactStore::__refreshCache, 100)

  _sortContactsCacheWithRankings: =>
    for accountId of @_contactCache
      rankings = ContactRankingStore.valueFor(accountId)
      continue unless rankings
      @_contactCache[accountId] = _.sortBy(
        @_contactCache[accountId],
        (contact) => (- (rankings[contact.email.toLowerCase()] ? 0) / 1)
      )

  _resetCache: =>
    @_contactCache = {}
    ContactRankingStore.reset()
    @trigger(@)

module.exports = new ContactStore()