# TODO: (whatupdave) rename to Bounty
class Task < Wip
  belongs_to :locker, class_name: 'User', foreign_key: 'locked_by'

  has_many :deliverables, foreign_key: 'wip_id'
  alias_method :design_deliverables, :deliverables

  has_many :code_deliverables, foreign_key: 'wip_id'
  has_many :copy_deliverables, foreign_key: 'wip_id'
  has_many :hearts, foreign_key: 'heartable_id'
  has_many :offers, foreign_key: "bounty_id"
  has_many :wip_workers, class_name: 'Wip::Worker', foreign_key: 'wip_id', inverse_of: :wip
  has_many :votes, :as => :voteable, :after_add => :vote_added
  has_many :workers, :through => :wip_workers, :source => :user
  has_many :news_feed_items, as: :target

  scope :allocated,   -> { where(state: :allocated) }
  scope :reviewing,   -> { where(state: :reviewing) }
  scope :won,         -> { joins(:awards) }
  scope :won_after,   -> (time) { won.where('awards.created_at >= ?', time) }
  scope :won_by,      -> (user) { won.where('awards.winner_id = ?', user.id) }
  scope :won_by_after, -> (user, time) { won.where('awards.winner_id = ?', user.id).where('awards.created_at >= ?', time) }

  AUTHOR_TIP = 0
  IN_PROGRESS = 'allocated'

  workflow_column :state
  workflow do
    state :open do
      event :allocate,    :transitions_to => :allocated
      event :award,       :transitions_to => :awarded
      event :close,       :transitions_to => :closed
      event :review_me,   :transitions_to => :reviewing
      event :unallocate,  :transitions_to => :open
    end
    state :allocated do
      event :allocate,    :transitions_to => :allocated
      event :unallocate,  :transitions_to => :open
      event :award,       :transitions_to => :awarded
      event :close,       :transitions_to => :resolved
      event :review_me,   :transitions_to => :reviewing
    end
    state :awarded do
      event :allocate,    :transitions_to => :awarded
      event :unallocate,  :transitions_to => :awarded
      event :award,       :transitions_to => :awarded
      event :close,       :transitions_to => :resolved
      event :review_me,   :transitions_to => :reviewing
    end
    state :closed do
      event :unallocate,  :transitions_to => :open
      event :reopen,      :transitions_to => :open
    end
    state :reviewing do
      event :allocate,    :transitions_to => :reviewing
      event :unallocate,  :transitions_to => :open
      event :reject,      :transitions_to => :open
      event :award,       :transitions_to => :awarded
      event :close,       :transitions_to => :resolved
      event :review_me,   :transitions_to => :reviewing
    end
    state :resolved do
      event :reopen,      :transitions_to => :open
    end

    after_transition { notify_state_changed }
  end

  def self.states
    workflow_spec.states.keys
  end

  def self.deliverable_types
    %w(design code copy other)
  end

  def awardable?
    true
  end

  def on_open_entry(prev_state, event, *args)
    assign_lowest_priority
  end

  def on_closed_entry(prev_state, event, *args)
    remove_priority
  end

  def on_resolved_entry(prev_state, event, *args)
    remove_priority
  end

  def assign_top_priority
    ActiveRecord::Base.transaction do
      update(priority: 0)
      recalculate_sibling_priorities
    end
  end

  def assign_lowest_priority
    ActiveRecord::Base.transaction do
      lowest_priority = product.tasks.where.not(state: ['closed', 'resolved'], priority: nil).order(priority: :desc).limit(1).pluck(:priority).first
      lowest_priority ||= 0
      update(priority: lowest_priority + 1)
    end
  end

  def remove_priority
    ActiveRecord::Base.transaction do
      update(priority: nil)
      recalculate_sibling_priorities
    end
  end

  def recalculate_sibling_priorities
    tasks = self.product.tasks.where.not(state: ['closed', 'resolved'], priority: nil)
    rankings_query = tasks.select('id, row_number() OVER (ORDER BY priority ASC) AS priority').to_sql
    tasks.where('wips.id = rankings.id').update_all("priority = rankings.priority FROM (#{rankings_query}) rankings")
  end

  def active_offers
    offers.group_by(&:user).flat_map { |u, o| o.sort_by(&:created_at).last }
  end

  def promoted?
    !promoted_at.nil?
  end

  def can_vote?(user)
    votes.where(user: user).none?
  end

  def assigned_to?(worker)
    workers.include?(worker)
  end

  def lock_bounty!(worker)
    update(locked_at: Time.now, locked_by: worker.id)
  end

  def unlock_bounty!
    update(locked_at: nil, locked_by: nil)
  end

  def start_work!(worker)
    self.workers << worker unless assigned_to?(worker)
    Analytics.track(
      user_id: worker.id,
      event: 'product.wip.start_work',
      properties: WipAnalyticsSerializer.new(self, scope: worker).as_json
    )
    allocate!(worker) unless self.workers.count > 1
    lock_bounty!(worker) if self.locked_at.nil?
  end

  def stop_work!(worker)
    self.update(workers: [])
    unlock_bounty!
    unallocate!(worker) if workers.empty?
  end

  def allocate(worker)
    add_activity worker, Activities::Assign do
      add_event(::Event::Allocation.new(user: worker))
    end
  end

  def unallocate(reviewer, reason = nil)
    StreamEvent.add_unallocated_event!(actor: reviewer, subject: self, target: product)

    add_event ::Event::Unallocation.new(user: reviewer, body: reason) do
      self.workers.delete_all
    end
  end

  def review_me(worker)
    start_work!(worker)

    add_activity worker, Activities::Post do
      add_event ::Event::ReviewReady.new(user: worker)
    end
  end

  def reject(reviewer)
    add_activity reviewer, Activities::Unassign do
      add_event ::Event::Rejection.new(user: reviewer) do
        self.workers.delete_all
      end
    end
  end

  def award(closer, winning_event, amount=nil, reason=nil)
    award_with_reason(closer, winning_event.user, reason, amount)
  end

  def award_with_reason(closer, winner, reason, amount=nil)
    stop_work!(winner)

    minting = nil
    award = nil
    add_activity(closer, Activities::Award) do
      win = ::Event::Win.new(user: closer, body: reason)
      add_event(win) do
        award = self.awards.create!(
          awarder: closer,
          winner: winner,
          event: win,
          wip: self,
          cents: (amount || earnable_cents)
        )

        minting = TransactionLogEntry.minted!(nil, Time.current, product, award.id, amount || contracts.total_cents)

        milestones.each(&:touch)
      end
    end

    CoinsMinted.new.perform(minting.id) if minting
    award
  end

  def award_pending_with_reason(awarder, guest, reason)
    awards.create!(
      awarder: awarder,
      guest: guest,
      wip: self,
      cents: self.earnable_cents,
      reason: reason
    ).tap do |award|
      AwardMailer.delay(queue: 'mailer').pending_award(guest.id, award.id)
    end
  end

  def work_submitted(submitter)
    review_me!(submitter) if can_review_me?
  end

  def current_posting
    postings.first
  end

  def winners
    awards.select(&:winner).map(&:winner).uniq
  end

  def open?
    closed_at.nil?
  end

  def contracts
    WipContracts.new(self)
  end

  def earnable_cents
    WipContracts.new(self).earnable_cents
  end

  def update_coins_cache!
    contracts.tap do |c|
      self.update!(
        total_coins_cache: c.total_cents,
        earnable_coins_cache: c.earnable_cents
      )
    end
  end

  def most_recent_other_wip_worker(user)
    return unless user
    wip_workers.where.not(user_id: user.id).order('created_at DESC').first
  end
end
