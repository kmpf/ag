require 'date'
require 'open3'
require 'set'
require 'tempfile'
require 'webrick'
require 'yaml'
gem 'rugged', '=0.21.0'
require 'rugged'
require 'paint'
require 'highline/import'

require 'include/cli-dispatcher'
require 'include/pager'

COLOR_BLUE = '#3465a4'
COLOR_RED = '#cc0000'
COLOR_GREEN = '#4e9a06'
COLOR_YELLOW = '#f9b935'

COLOR_CATEGORY = COLOR_BLUE
COLOR_ISSUE = COLOR_GREEN

class Ag
    
    def initialize()
        srand()

        @config = Rugged::Config.global.to_hash
        
        @editor = ENV['EDITOR'] || 'nano'

        unless ARGV.first == 'help'
            begin
                @repo = Rugged::Repository.discover(Dir::pwd())
            rescue Rugged::RepositoryError => e
                unless ENV.include?('COMP_LINE')
                    puts e 
                end
                exit(1)
            end
            
            if @repo.branches['_ag']
                ensure_git_hook_present()
            end
        end
        
        CliDispatcher::launch do |ac|
            ac.option('help') do |ac|
                ac.option('cat') do |ac|
                    ['new', 'list', 'show', 'edit', 'reparent', 'rm'].each do |x|
                        ac.option(x)
                    end
                end
                ['new', 'list', 'show', 'oneline', 'edit',
                 'connect', 'disconnect', 'start', 'rm', 
                 'search', 'log', 'pull', 'push'].each do |x|
                    ac.option(x)
                end
                ac.handler { |args| run_pager(); show_help(args) }
            end
            
            # Category commands
            
            ac.option('cat') do |ac|
                
                ac.option('new') do |ac|
                    # define current categories (recursive = false) for auto-completion
                    define_autocomplete_categories(ac)
                    ac.handler { |args| new_category(args) }
                end
                
                ac.option('list') do |ac|
                    ac.handler { run_pager(); list_categories() }
                end
                
                ac.option('show') do |ac|
                    define_autocomplete_categories(ac)
                    ac.handler { |args| run_pager(); show_object(args.first) }
                end
                
                ac.option('edit') do |ac|
                    define_autocomplete_categories(ac)
                    ac.handler { |args| edit_object(args.first) }
                end
                
                ac.option('reparent') do |ac|
                    define_autocomplete_categories(ac) do |ac, collected_parts|
                        ac.option('null')
                        define_autocomplete_categories(ac, false, false, Set.new(collected_parts[2, collected_parts.size - 2]))
                    end
                    ac.handler { |args| reparent_category(args) }
                end
                
                ac.option('rm') do |ac|
                    define_autocomplete_categories(ac)
                    ac.handler { |args| rm_category(args.first) }
                end
                
            end
            
            # Issue commands
            
            ac.option('new', nil, true) do |ac, collected_parts|
                define_autocomplete_categories(ac, false, false, Set.new(collected_parts[1, collected_parts.size - 1]))
                ac.handler { |args| new_issue(args) }
            end
            
            ac.option('list', nil, true) do |ac, collected_parts|
                define_autocomplete_categories(ac, false, false, Set.new(collected_parts[1, collected_parts.size - 1]))
                ac.handler { |args| run_pager(); list_issues(args) }
            end
            
            ac.option('show') do |ac|
                define_autocomplete_issues(ac)
                ac.handler { |args| run_pager(); show_object(args.first) }
            end
                
            ac.option('oneline') do |ac|
                define_autocomplete_issues(ac)
                ac.handler { |args| oneline(args.first) }
            end
                
            ac.option('edit') do |ac|
                define_autocomplete_issues(ac)
                ac.handler { |args| edit_object(args.first) }
            end
                
            ac.option('connect') do |ac|
                define_autocomplete_issues(ac, false, true) do |ac, collected_parts|
                    issue_id = collected_parts[1]
                    specified_cats = Set.new(collected_parts[2, collected_parts.size - 2])
                    issue = load_issue(issue_id)
                    specified_cats |= Set.new(issue[:categories])
                    define_autocomplete_categories(ac, false, false, specified_cats)
                end
                ac.handler { |args| connect_categories_to_issue(args) }
            end
                
            ac.option('disconnect') do |ac|
                define_autocomplete_issues(ac, false, true) do |ac, collected_parts|
                    issue_id = collected_parts[1]
                    specified_cats = Set.new(collected_parts[2, collected_parts.size - 2])
                    issue = load_issue(issue_id)
                    connected_categories = Set.new(issue[:categories])
                    define_autocomplete_categories(ac, false, false, specified_cats, connected_categories)
                end
                ac.handler { |args| disconnect_categories_from_issue(args) }
            end
                
            ac.option('start') do |ac|
                define_autocomplete_issues(ac)
                ac.handler { |args| start_working_on_issue(args.first) }
            end
                
            ac.option('rm') do |ac|
                define_autocomplete_issues(ac)
                ac.handler { |args| rm_issue(args.first) }
            end
                
            # Miscellaneous commands
            
            ac.option('search') do |ac|
                define_autocomplete_keywords(ac)
                ac.handler { |args| run_pager(); search(args) }
            end
                
            ac.option('log') do |ac|
                ac.handler { |args| run_pager(); log() }
            end
                
            ac.option('pull') do |ac|
                ac.handler { |args| pull() }
            end
                
            ac.option('push') do |ac|
                ac.handler { |args| push() }
            end
                
        end
        puts "Unknown command: #{ARGV.first}. Try 'ag help' for a list of possible commands."
    end

    # auto-completion helper: define categories with slugs and slug parts
    # If recursive == false, only define current categories
    # If recursive == true, also walk back in history and define removed categories
    # Use include to specify IDs to use (instead of using all_ids)
    # Use exclude to specify completions that should be excluded
    def define_autocomplete_object(type, ac, recursive = false, inception = false, exclude = Set.new(), include = nil, &block)
        use_ids = include
        use_ids ||= all_ids(recursive, type)
        use_ids.each do |id|
            object = load_object(id)
            next if exclude.include?(object[:slug]) || exclude.include?(object[:id])
            ac.option(object[:slug], nil, inception, &block)
            ac.option(object[:slug], object[:slug], inception, &block)
            object[:slug_pieces].each do |p|
                ac.option(p, object[:slug], inception, &block)
            end
        end
    end
    
    def define_autocomplete_categories(ac, recursive = false, inception = false, exclude = Set.new(), include = nil, &block)
        define_autocomplete_object('category', ac, recursive, inception, exclude, include, &block)
    end
    
    def define_autocomplete_issues(ac, recursive = false, inception = false, exclude = Set.new(), include = nil, &block)
        define_autocomplete_object('issue', ac, recursive, inception, exclude, include, &block)
    end
    
    def define_autocomplete_keywords(ac, recursive = false, inception = false, exclude = Set.new(), &block)
        (Set.new(all_issue_ids(recursive)) | Set.new(all_category_ids(recursive))).each do |id|
            object = load_object(id)
            object[:slug_pieces].each do |p|
                next if exclude.include?(p)
                ac.option(p, nil, inception, &block)
            end
        end
    end
    
    def ensure_git_hook_present()
        hook_path = File::join(@repo.path, 'hooks', 'prepare-commit-msg')
        unless File::exists?(hook_path)
            File::open(hook_path, 'w') do |f|
                f.write(File::read(File::join(File.expand_path(File.dirname(__FILE__)), 'prepare-commit-msg.txt')))
            end
            File::chmod(0755, hook_path)
        end
    end

    # return all IDs already assigned, with its most recent rev
    # if recursive == true, this includes IDs which have already
    # been removed (walks entire history of _ag branch, if present)
    # return all IDs if which == nil - it can also be 'categories' or 'issues'
    def all_ids_with_sha1(recursive = true, which = nil)
        ids = {}
        
        ag_branch = @repo.branches['_ag']
        if ag_branch
            walker = Rugged::Walker.new(@repo)
            walker.push(ag_branch.target)
            walker.each do |commit|
                commit.tree.walk(:postorder) do |path, obj|
                    next unless obj[:type] == :blob
                    if which
                        next if path != which + '/'
                    end
                    id = obj[:name]
                    next unless id =~ /^[a-z]{2}\d{4}$/
                    ids[id] ||= commit.oid
                end
                break unless recursive
            end
        end
        
        return ids
    end

    def all_ids(recursive = true, which = nil)
        ids = all_ids_with_sha1(recursive, which)
        return Set.new(ids.keys)
    end
    
    def all_category_ids(recursive = true)
        return all_ids(recursive, 'category')
    end

    def all_issue_ids(recursive = true)
        return all_ids(recursive, 'issue')
    end

    def gen_id()
        existing_ids = all_ids(true, nil)
        loop do
            result = ''
            2.times { result += (rand(26) + 'a'.ord).chr }
            4.times { result += (rand(10) + '0'.ord).chr }
            return result if !existing_ids.include?(result)
        end
    end
    
    def call_editor(template)
        file = Tempfile.new('ag')
        contents = ''
        begin
            File::open(file.path, 'wb') do |f|
                f.write(template)
            end
            system("#{@editor} #{file.path}")
            File::open(file.path, 'rb') do |f|
                contents = f.read()
            end
        ensure
            file.close
            file.unlink
        end
        return contents
    end

    def parse_object(s, id)
        id = id[0, 6]
        original = s.dup
        
        lines = s.split("\n")
        if lines[0].index('Summary:') != 0
            raise 'Missing summary field in object'
        end
        
        summary = lines[0].sub('Summary:', '').strip
        lines.delete_at(0)
        
        parent = nil
        if !lines.empty? && lines[0].index('Parent:') == 0
            parent = lines[0].sub('Parent:', '').strip[0, 6]
            parent = nil if parent == 'null'
            lines.delete_at(0)
        end
        
        categories = []
        if !lines.empty? && lines[0].index('Categories:') == 0
            categories = lines[0].sub('Categories:', '').strip.split(' ').map do |x| 
                x.strip
                x = x[0, x.size - 1] if x[-1] == ','
                x.strip[0, 6]
            end.select do |x|
                !x.empty?
            end
            lines.delete_at(0)
        end
        
        description = lines.join("\n")
        description.strip!
        
        summary_pieces = summary.downcase.gsub(/[^a-z0-9]/, ' ').split(' ').select { |x| !x.strip.empty? }[0, 8]
        slug = "#{id}-#{summary_pieces.join('-')}"
        
        return {:id => id, :original => original, :parent => parent,
                :categories => categories, :summary => summary, 
                :description => description, :slug => slug, :slug_pieces => summary_pieces}
    end

    def load_object(id)
        id = id[0, 6]
        ag_branch = @repo.branches['_ag']
        if ag_branch
            walker = Rugged::Walker.new(@repo)
            walker.push(ag_branch.target)
            walker.each do |commit|
                commit.tree.walk(:postorder) do |path, obj|
                    next unless obj[:type] == :blob
                    test_id = obj[:name]
                    if test_id == id
                        # found something!
                        object = parse_object(@repo.lookup(obj[:oid]).content, id)
                        object[:type] = path[0, path.size - 1]
                        if ['issue', 'category'].include?(object[:type])
                            return object
                        end
                    end
                end
            end
        end
        raise "No such object: [#{id}]."
    end
    
    def load_issue(id)
        object = load_object(id)
        if object[:type] != 'issue'
            raise "Expected an issue, got something else."
        end
        return object
    end
    
    def load_category(id)
        object = load_object(id)
        if object[:type] != 'category'
            raise "Expected a category, got something else."
        end
        return object
    end
    
    def find_commits_for_issues()
        results = {}
        walker = Rugged::Walker.new(@repo)
        walker.push(@repo.head.target)
        walker.each do |commit|
            message = commit.message
            if message =~ /^\[[a-z]{2}\d{4}\]/
                id = message[1, 6]
                results[id] ||= {
                    :count => 0,
                    :time_min => commit.time,
                    :time_max => commit.time,
                    :authors => Set.new()
                }
                results[id][:count] += 1
                results[id][:authors] << "#{commit.author[:name]} <#{commit.author[:email]}>"
                results[id][:time_min] = commit.time if commit.time < results[id][:time_min]
                results[id][:time_max] = commit.time if commit.time > results[id][:time_max]
            end
        end
        return results
    end
    
    def check_if_ag_is_set_up()
        unless @repo.branches['_ag']
            remote_ag_branches = @repo.branches.select { |x| x.name[-4, 4] == '/_ag' }.map { |x| x.name }
            if remote_ag_branches.size == 1
                # There's exactly one remote _ag branch, fetch and track it.
                system("git checkout --track -b _ag #{remote_ag_branches.first}")
            elsif remote_ag_branches.size > 1
                puts "There is more than one remote _ag branch: #{remote_ag_branches.join(', ')} and"
                puts "I don't know which one to pick. Pick one and fetch it with:"
                ptus "git checkout --track -b _ag [url]"
            else
                puts "Ag has not been set up for this repository, as there's no _ag branch yet."
                puts "You can use `ag cat new` or `ag new` to define categories or issues, which"
                puts "will set up Ag in this repository."
            end
        end
    end

    def list_issues(args)

        check_if_ag_is_set_up()
        
        filter_cats = nil
        unless args.empty?
            filter_cats = args.map do |cat_id|
                category = load_category(cat_id)
                category[:id]
            end
        end
        commits_for_issues = find_commits_for_issues()
        all_issues = {}
        all_issue_ids(false).each do |id|
            issue = load_issue(id)
            all_issues[id] = issue
        end
        
        all_issues.keys.sort.each do |id|
            issue = all_issues[id]
            line = Paint["[#{issue[:id]}] #{commits_for_issues.include?(id) ? '*' : ' '} #{issue[:summary]}", COLOR_ISSUE]
            cats = issue[:categories].map do |cat_id|
                category = load_category(cat_id)
                category[:id]
            end
            if filter_cats
                # category filtering is on, lets intersect!
                next if (Set.new(cats) & Set.new(filter_cats)).empty?
            end
            # promote cat IDs to summaries ('cause it's oh so pretty!)
            cats = cats.map do |cat_id|
                category = load_category(cat_id)
                category[:summary]
            end
            unless cats.empty?
                line += Paint[" (#{cats.join(' / ')})", COLOR_CATEGORY]
            end
            puts line
        end
        
    end

    def list_categories()
        commits_for_issues = find_commits_for_issues()
        # TODO: Handle commits_for_issues
        all_categories = {}
        ids_by_parent = {}
        all_category_ids(false).each do |id|
            category = load_category(id)
            all_categories[id] = category
            ids_by_parent[category[:parent]] ||= []
            ids_by_parent[category[:parent]] << id
            # TODO: handle orphaned nodes
        end
        
        def print_tree(parent, all_categories, ids_by_parent, commits_for_issues, prefix = '')
            count = ids_by_parent[parent].size
            ids_by_parent[parent].sort do |a, b|
                    category_a = all_categories[a]
                    category_b = all_categories[b]
                    category_a[:summary].downcase <=> category_b[:summary].downcase
                end.each_with_index do |id, index|
                category = all_categories[id]
                box_art = ''
                if parent
                    if index < count - 1
                        box_art = "\u251c\u2500\u2500"
                    else
                        box_art = "\u2514\u2500\u2500"
                    end
                end
#                 puts "[#{id}] #{commits_for_issues.include?(id) ? '*' : ' '} #{prefix}#{box_art}#{issue[:summary]}"
                puts Paint["[#{id}] #{prefix}#{box_art}#{category[:summary]}", COLOR_CATEGORY]
                if ids_by_parent.include?(id)
                    print_tree(id, all_categories, ids_by_parent, commits_for_issues, parent ? prefix + (index < count - 1 ? "\u2502  " : "   ") : prefix)
                end
            end
        end

        if ids_by_parent[nil]
            print_tree(nil, all_categories, ids_by_parent, commits_for_issues)
        end
    end

    def get_oneline(id)
        id = id[0, 6]
        object = load_object(id)
        parts = [object[:summary]]
        p = object
        while p[:parent]
            p = load_object(p[:parent])
            parts.unshift(p[:summary])
        end
        return "[#{id}] #{parts.join(' / ')}"
    end
    
    def oneline(id)
        id = id[0, 6]
        puts get_oneline(id)
    end
    
    def object_to_s(object)
        result = ''
        
        result += "Summary: #{object[:summary]}\n"
        if object[:type] == 'category'
            if object[:parent]
                parent_s = "#{object[:parent]}-orphaned"
                begin
                    parent_category = load_category(object[:parent])
                    parent_s = parent_category[:slug]
                rescue
                end
                result += "Parent: #{parent_s}\n" 
            end
        elsif object[:type] == 'issue'
            unless object[:categories].empty?
                result += "Categories: #{object[:categories].map { |x| load_category(x)[:slug]}.to_a.sort.join(', ')}\n" if object[:categories]
            end
        else
            raise "Internal error."
        end
        result += "\n"
        result += object[:description]
        
        return result
    end

    # commit an object OR delete it if object == nil && really_delete == true
    def commit_object(id, object, comment, really_delete = false)
        id = id[0, 6]
        index = Rugged::Index.new
        begin
            @repo.rev_parse('_ag').tree.walk(:postorder) do |path, blob|
                next unless blob[:type] == :blob
                unless blob[:name] == id
                    index.add(:path => path + blob[:name], :oid => blob[:oid], :mode => blob[:filemode])
                end
            end
        rescue Rugged::ReferenceError => e
            # There's no _ag branch yet, but don't worry. It just means we don't
            # have any files to add yet
        end

        if object
            oid = @repo.write(object_to_s(object), :blob)
            index.add(:path => object[:type].to_s + '/'+ id, :oid => oid, :mode => 0100644)
        else
            unless really_delete
                puts "Ag internal error: No object passed to commit_object, yet really_delete is not true."
                exit(2)
            end
        end

        options = {}
        options[:tree] = index.write_tree(@repo)

        options[:author] = { :email => @config['user.email'], :name => @config['user.name'], :time => Time.now }
        options[:committer] = { :email => @config['user.email'], :name => @config['user.name'], :time => Time.now }
        options[:message] ||= comment
        options[:parents] = []
        if @repo.branches['_ag']
            options[:parents] = [ @repo.rev_parse_oid('_ag') ].compact
            options[:update_ref] = 'refs/heads/_ag'
        end

        commit = Rugged::Commit.create(@repo, options)
        
        unless @repo.branches['_ag']
            @repo.create_branch('_ag', commit)
        end
        puts options[:message]
    end

    def new_category(args)
        parent_cat = nil

        if args.size > 0
            begin
                parent_cat = load_category(args.first)
                args.shift
            rescue RuntimeError
                parent_cat = nil
            end
        end
        summary = args.join(' ')
        id = gen_id()
        
        template = "Summary: #{summary}"
        if parent_cat
            template += "\nParent: #{parent_cat[:slug]}"
        end
        if summary.strip.empty?
            template = call_editor(template)
        end
        category = parse_object(template, id)
        category[:type] = 'category'
        
        if category[:summary].empty?
            raise "Aborting due to empty summary."
        end
        
        commit_object(id, category, "Created new category: #{category[:slug]}")
    end

    def new_issue(args)
        connected_cats = Set.new()
        while !args.empty?
            begin
                cat = args.first[0, 6]
                category = load_category(cat)
                connected_cats << cat
                args.shift
            rescue RuntimeError
                break
            end
        end
        id = gen_id()
        
        summary = args.join(' ')
        template = "Summary: #{summary}"
        unless connected_cats.empty?
            template += "\nCategories: #{connected_cats.map { |x| load_category(x)[:slug]}.to_a.sort.join(', ')}"
        end
        issue = parse_object(call_editor(template), id)
        issue[:type] = 'issue'
        
        if issue[:summary].empty?
            raise "Aborting due to empty summary."
        end
        
        commit_object(id, issue, "Added issue: #{issue[:slug]}")
    end

    def show_object(id)
        id = id[0, 6]
        object = load_object(id)
        ol = get_oneline(id)
        heading = "#{'-' * ol.size}\n#{ol}\n#{'-' * ol.size}"
        if object[:type] == 'category'
            heading = heading.split("\n").map { |x| Paint[x, COLOR_CATEGORY] }.join("\n")
        elsif object[:type] == 'issue'
            heading = heading.split("\n").map { |x| Paint[x, COLOR_ISSUE] }.join("\n")
        end
        puts heading
        puts object_to_s(object)
    end
    
    def edit_object(id)
        id = id[0, 6]
        object = load_object(id)
        object_type = object[:type]
        
        before = object_to_s(object)
        modified_object = call_editor(before)
        if modified_object != before
            object = parse_object(modified_object, id)
            object[:type] = object_type
            
            commit_object(id, object, "Modified #{object_type}: #{object[:slug]}")
        else
            puts "Leaving #{object_type} [#{id}] unchanged: #{object[:summary]}"
        end
    end
    
    def reparent_category(args)
        if args.size != 2
            raise "Reparent requires two arguments (child and new parent)."
        end
        
        objects = []
        (0..1).each do |index|
            if index == 1 && args[index] == 'null'
                objects << nil
            else
                objects << load_category(args[index])
            end
        end
        
        objects[0][:parent] = (objects[1] ? objects[1][:id] : nil)

        commit_object(objects[0][:id], objects[0], "Set parent of #{objects[0][:slug]} to #{(objects[1] ? objects[1][:slug] : 'null')}")
    end
    
    def rm_category(id)
        id = id[0, 6]
        cat = load_category(id)
        
        puts "Removing category: #{get_oneline(id)}"
    
        # If this category has currently any children, we shouldn't remove it
        all_category_ids(false).each do |check_id|
            check_cat = load_category(check_id)
            if check_cat[:parent] == id
                puts "Error: This category has children, unable to continue."
                exit(1)
            end
        end
        
        # If any current issues are connected to this category, we shouldn't delete it
        all_issue_ids(false).each do |check_id|
            issue = load_issue(check_id)
            if issue[:categories].include?(cat[:id])
                puts "Error: There are issues which are connected to this category, unable to continue."
                exit(1)
            end
        end
        
        
        response = ask("Are you sure you want to remove this category [y/N]? ")
        if response.downcase == 'y'
            commit_object(id, nil, "Removed category: #{cat[:slug]}", true)
        else
            puts "Leaving category #{cat[:slug]} unchanged."
        end
    end
    
    def connect_categories_to_issue(args)
        if args.size < 2
            raise "Two or more arguments required for connect_categories_to_issue."
        end
        issue = load_issue(args.first)
        (1...args.size).each do |i|
            category = load_category(args[i])
            issue[:categories] = issue[:categories].select do |x|
                x != category[:id]
            end
            issue[:categories] << category[:id]
        end
        commit_object(issue[:id], issue, "Connected issue #{issue[:slug]} to #{args.size - 1} categor#{((args.size - 1) == 1) ? 'y' : 'ies'}", true)
    end

    def disconnect_categories_from_issue(args)
        if args.size < 2
            raise "Two or more arguments required for disconnect_categories_from_issue."
        end
        issue = load_issue(args.first)
        (1...args.size).each do |i|
            category = load_category(args[i])
            unless issue[:categories].include?(category[:id])
                raise "Issue #{issue[:slug]} is not connected to category #{category[:slug]}"
            end
            issue[:categories] = issue[:categories].select do |x|
                x != category[:id]
            end
        end
        commit_object(issue[:id], issue, "Disconnected issue #{issue[:slug]} from #{args.size - 1} categor#{((args.size - 1) == 1) ? 'y' : 'ies'}", true)
    end

    def rm_issue(id)
        id = id[0, 6]
        issue = load_issue(id)
        
        puts "Removing issue: #{get_oneline(id)}"
    
        response = ask("Are you sure you want to remove this issue [y/N]? ")
        if response.downcase == 'y'
            commit_object(id, nil, "Removed issue: #{issue[:slug]}", true)
        else
            puts "Leaving issue #{issue[:slug]} unchanged."
        end
    end
    
    def start_working_on_issue(id)
        id = id[0, 6]
        issue = load_issue(id)
        existing_branches = @repo.branches.select { |b| b.name[0, id.size + 1] == id + '-' }
        if existing_branches.empty?
            system("git checkout -b #{issue[:slug]}")
        elsif existing_branches.size == 1
            system("git checkout #{existing_branches.first.name}")
        else
            puts "There are multiple branches connected to the issue, can't decide which one to check out:"
            puts existing_branches.map { |x| x.name }.join("\n")
        end
    end
    
    def search(keywords)
        all_ids(true).each do |id|
            object = load_object(id)
            found_something = false
            keywords.each do |keyword|
                if object[:original].downcase.include?(keyword.downcase)
                    s = get_oneline(id)
                    s = Paint[s, COLOR_CATEGORY] if object[:type] == 'category'
                    s = Paint[s, COLOR_ISSUE] if object[:type] == 'issue'
                    puts s
                end
            end
        end
    end

=begin    
    def web()
        root = File::join(File.expand_path(File.dirname(__FILE__)), 'web')
        server = WEBrick::HTTPServer.new(:Port => 19816, :DocumentRoot => root)
        
        trap('INT') do 
            server.shutdown()
        end
        
        server.mount_proc('/update-parent') do |req, res|
            parts = req.unparsed_uri.split('/')
            id = parts[2]
            parent_id = parts[3]
            issue = load_issue(id)
            begin
                parent = load_issue(parent_id)
            rescue
                parent_id = nil
            end
            issue[:parent] = parent_id
            commit_issue(id, issue, 'Changed parent of issue')
        end
        
        server.mount_proc('/read-issue') do |req, res|
            parts = req.unparsed_uri.split('/')
            id = parts[2]
            issue = load_issue(id)
            res.body = issue.to_json()
        end
        
        server.mount_proc('/ag.json') do |req, res|
            all_issues = {}
            ids_by_parent = {}
            all_ids(false).sort.each do |id|
                issue = load_issue(id)
                all_issues[id] = issue
                ids_by_parent[issue[:parent]] ||= []
                ids_by_parent[issue[:parent]] << id
            end
            
            def walk_tree(parent, all_issues, ids_by_parent)
                return unless ids_by_parent[parent]
                items = []
                count = ids_by_parent[parent].size
                ids_by_parent[parent].sort do |a, b|
                    issue_a = all_issues[a]
                    issue_b = all_issues[b]
                    issue_a[:summary].downcase <=> issue_b[:summary].downcase
                end.each_with_index do |id, index|
                    issue = all_issues[id]
                    items << {'id' => id, 'summary' => issue[:summary]}
                    if ids_by_parent.include?(id)
                        items.last['children'] = walk_tree(id, all_issues, ids_by_parent)
                    end
                end
                return items
            end
            
            items = walk_tree(nil, all_issues, ids_by_parent)
            res.body = items.to_json()
        end        

        puts
        puts "Please go to >>> http://localhost:19816 <<< to interact with the issue tracker."
        puts
        
        fork do
            system("google-chrome http://localhost:19816")
        end
        
        server.start
    end
=end    
    
    def log()
        ag_branch = @repo.branches['_ag']
        if ag_branch
            
            walker = Rugged::Walker.new(@repo)
            walker.push(ag_branch.target)
            max_author_width = 1
            walker.each do |commit|
                max_author_width = commit.author[:name].size if commit.author[:name].size > max_author_width
            end
            
            walker = Rugged::Walker.new(@repo)
            walker.push(ag_branch.target)
            walker.each do |commit|
                puts "#{commit.author[:time].strftime('%Y/%m/%d %H:%M:%S')} | #{sprintf('%-' + max_author_width.to_s + 's', commit.author[:name])} | #{commit.message}"
            end
        end
    end
    
    def pull()
        remote_name = 'origin'
        check_if_ag_is_set_up()
        system("git fetch #{remote_name} _ag")
        # the line below should work because we have just fetched a single branch
        remote_tip = `git rev-parse FETCH_HEAD`.split(' ').first
        local_tip = `git show-ref refs/heads/_ag`.split(' ').first
        if local_tip != remote_tip
            # We have to update to branch and merge. See if we can do a fast-forward.
            if `git merge-base #{local_tip} #{remote_tip}`.strip == local_tip
                # It's super easy!
                puts "Fast forward!"
                system("git update-ref -m \"merge #{remote_tip[0, 7]}: Fast forward\" refs/heads/_ag #{remote_tip}")
            else
                puts "Unable to fast-forward."
                puts "Unfortunately, existing upstream changes could not be merged automatically."
                puts "To fix this, check out the _ag branch, pull the upstream changes and resolve"
                puts "conflicts manually."
            end
        end
    end
    
    def push()
        remote_name = 'origin'
        check_if_ag_is_set_up()
        system("git push #{remote_name} _ag")
    end
    
    def show_help(args)
        items = HELP_TEXT.strip.split(/^__(.+)$/)
        items.shift
        texts = {}
        i = 0
        while (i + 1) < items.size
            texts[items[i]] = items[i + 1].strip
            i += 2
        end
        key = args.join('/')
        if texts.include?(key)
            puts texts[key]
        else
            puts texts['default']
        end
    end
    HELP_TEXT = <<END
__default
Ag - issue tracking intertwined with Git

Usage: ag <command> [<args>]

Available category-related commands:
cat new       Create a new category
cat list      List all categories
cat show      Show raw category information
cat edit      Edit a new category
cat reparent  Re-define the parent category of a category
cat rm        Remove a category

Available issue-related commands:
new           Create a new issue
list          List all issues
show          Show raw issue information
oneline       Show condensed issue information in a single line
edit          Edit an issue
connect       Connect an issue to a category
disconnect    Disconnect an issue from a category
start         Start working on an issue
rm            Remove an issue

Miscellaneous commands:
pull          Pull upstream changes
push          Push changes upstream
search        Search for categories or issues
log           Show of a log of Ag activities
help          Show usage information

See 'ag help <command>' for more information on a specific command.
Ag supports tab completion pretty well - try to specify category or 
issue IDs via keywords, they will be auto-completed.

__cat/new
Usage: ag cat new [<parent>] [<title>]

Create a new category. Optionally, specify a parent category ID and/or the category title.

__cat/list
Usage: ag cat list

Show all categories as a tree (ASCII art).

__cat/show
Usage: ag cat show <category>

Show detailed category information.

__cat/edit
Usage: ag cat edit <category>

Edit category information.

__cat/reparent
Usage: ag cat reparent <child> <parent>

Assign <parent> as the parent category of <child> (<parent> can be null).

__cat/rm
Usage: ag cat rm <category>

Remove a category.

This won't work if the category has child categories or if there are currently
any issues connected to this category. Interactive user confirmation is required.

__new
Usage: ag new [<categories>] [<title>]

Create a new issue. Optionally, categories can be specified which the issue
should be connected to. It is possible to add and remove connections to categories
at any time. You may specify the issue title on the command line.

__list
Usage: ag list

List all issues.

__show
Usage: ag show <issue>
Show raw issue information.

__oneline
Usage: ag oneline <issue>
Show condensed issue information in a single line.

__edit
Usage: ag edit <issue>
Edit an issue.

__connect
Usage: ag connect <issue> <category> [<category> ...]
Connect an issue to one or more categories.

__disconnect
Usage: ag disconnect <issue> <category> [<category> ...]
Disconnect an issue from one or more categories.

__start
Usage: ag start <issue>

Start working on an issue. Ag will create a topic branch for the specified issue.
The branch name starts with the issue ID followed by a dash, and through this 
pattern the git prepare-commit-message hook is able to know which issue all 
commits made in this branch should be connected to.

__rm
Usage: ag rm <issue>
Remove an issue.

__pull
Usage: ag pull
Pull upstream changes.

__push
Usage: ag push
Push changes upstream.

__search
Usage: ag search <keywords>
Search for categories or issues.

__log:
Usage: ag log
Show of a log of Ag activities.
END
end