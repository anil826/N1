NylasStore = require 'nylas-store'
_ = require 'underscore'
{DatabaseStore,
 AccountStore,
 ThreadCountsStore,
 WorkspaceStore,
 Actions,
 Label,
 Folder,
 Message,
 MailboxPerspective,
 FocusedPerspectiveStore,
 SyncbackCategoryTask,
 DestroyCategoryTask,
 CategoryHelpers,
 CategoryStore,
 Thread} = require 'nylas-exports'

class AccountSidebarStore extends NylasStore
  constructor: ->
    @_sections = []
    @_account = FocusedPerspectiveStore.current()?.account
    @_registerListeners()
    @_updateSections()

  ########### PUBLIC #####################################################

  currentAccount: ->
    @_account

  sections: ->
    @_sections

  selected: ->
    if WorkspaceStore.rootSheet() is WorkspaceStore.Sheet.Threads
      FocusedPerspectiveStore.current()
    else
      WorkspaceStore.rootSheet()

  ########### PRIVATE ####################################################

  _registerListeners: ->
    @listenTo WorkspaceStore, @_updateSections
    @listenTo CategoryStore, @_updateSections
    @listenTo ThreadCountsStore, @_updateSections
    @listenTo FocusedPerspectiveStore, => @_onPerspectiveChanged
    @configSubscription = NylasEnv.config.observe(
      'core.workspace.showUnreadForAllCategories',
      @_updateSections
    )

  _onPerspectiveChanged: =>
    account = FocusedPerspectiveStore.current()?.account
    if account?.id isnt @_account?.id
      @_uptdateSections()
    @_trigger()

  _updateSections: =>
    # TODO As it is now, if the current account is null, we  will display the
    # categories for all accounts.
    # Update this to reflect UI decision for sidebar

    # Compute hierarchy for userCategoryItems using known "path" separators
    # NOTE: This code uses the fact that userCategoryItems is a sorted set, eg:
    #
    # Inbox
    # Inbox.FolderA
    # Inbox.FolderA.FolderB
    # Inbox.FolderB
    #
    userCategoryItemsHierarchical = []
    userCategoryItemsSeen = {}
    for category in CategoryStore.userCategories(@_account)
      # https://regex101.com/r/jK8cC2/1
      itemKey = category.displayName.replace(/[./\\]/g, '/')

      parent = null
      parentComponents = itemKey.split('/')
      for i in [parentComponents.length..1] by -1
        parentKey = parentComponents[0...i].join('/')
        parent = userCategoryItemsSeen[parentKey]
        break if parent

      if parent
        itemDisplayName = category.displayName.substr(parentKey.length+1)
        item = @_sidebarItemForCategory(category, itemDisplayName)
        parent.children.push(item)
      else
        item = @_sidebarItemForCategory(category)
        userCategoryItemsHierarchical.push(item)
      userCategoryItemsSeen[itemKey] = item

    # Our drafts are displayed via the `DraftListSidebarItem` which
    # is loading into the `Drafts` Sheet.
    standardCategories = _.reject CategoryStore.standardCategories(@_account), (category) =>
      category.name is "drafts"

    standardCategoryItems = _.map standardCategories, (cat) => @_sidebarItemForCategory(cat)
    starredItem = @_sidebarItemForMailView('starred', MailboxPerspective.forStarred(@_account))

    # Find root views and add them to the bottom of the list (Drafts, etc.)
    standardItems = standardCategoryItems
    standardItems.splice(1, 0, starredItem)

    customSections = {}
    for item in WorkspaceStore.sidebarItems()
      if item.section
        customSections[item.section] ?= []
        customSections[item.section].push(item)
      else
        standardItems.push(item)

    @_sections = []
    @_sections.push
      label: 'Mailboxes'
      items: standardItems

    for section, items of customSections
      @_sections.push
        label: section
        items: items

    @_sections.push
      label: CategoryHelpers.categoryLabel(@_account)
      items: userCategoryItemsHierarchical
      iconName: CategoryHelpers.categoryIconName(@_account)
      createItem: @_createCategory
      destroyItem: @_destroyCategory

    @trigger()

  _sidebarItemForMailView: (id, filter) =>
    new WorkspaceStore.SidebarItem
      id: id,
      name: filter.name,
      mailboxPerspective: filter

  _sidebarItemForCategory: (category, shortenedName) =>
    new WorkspaceStore.SidebarItem
      id: category.id,
      name: shortenedName || category.displayName
      mailboxPerspective: MailboxPerspective.forCategory(@_account, category)
      unreadCount: @_itemUnreadCount(category)

  _createCategory: (displayName) ->
    # TODO this needs an account param
    return unless @_account?
    CategoryClass = @_account.categoryClass()
    category = new CategoryClass
      displayName: displayName
      accountId: @_account.id
    Actions.queueTask(new SyncbackCategoryTask({category}))

  _destroyCategory: (sidebarItem) ->
    category = sidebarItem.mailboxPerspective.category
    return if category.isDeleted is true
    Actions.queueTask(new DestroyCategoryTask({category}))

  _itemUnreadCount: (category) =>
    unreadCountEnabled = NylasEnv.config.get('core.workspace.showUnreadForAllCategories')
    if category and (category.name is 'inbox' or unreadCountEnabled)
      return ThreadCountsStore.unreadCountForCategoryId(category.id)
    return 0

module.exports = new AccountSidebarStore()