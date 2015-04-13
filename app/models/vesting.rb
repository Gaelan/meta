class Vesting < ActiveRecord::Base
  belongs_to :proposal
  belongs_to :product
  belongs_to :user

  scope :active, -> { where('expiration_date > ?', Time.now) }
  scope :expired, -> { where('expiration_date <= ?', Time.now) }

  def payout
    coins_each = self.coins / self.intervals
    to_id = self.user_id
    product = self.proposal.product

    TransactionLogEntry.create!(
      transaction_id: SecureRandom.uuid,
      created_at: Time.now,
      product: product,
      action: 'credit',
      wallet_id: to_id,
      cents: coins_each
    )
    puts "Paying #{coins_each} coins in #{product.name} to #{self.user.username}."
    intervals = self.intervals_paid + 1
    self.update!({intervals_paid: intervals})

  end

  def check_for_payout
    time_period = self.expiration_date - self.start_date
    interval_time = time_period / self.intervals
    time_diff = Time.now - self.start_date
    should_be_paid = (time_diff / interval_time).to_i
    unpaid = (time_diff / interval_time).to_i - self.intervals_paid
    (0..unpaid-1).each do |a|
      self.payout
    end
  end

  def expired?
    self.expiration_date - Time.now < 0
  end

  def vestings_in_won_proposals(product)
    product.proposals.select(&:won?).map(&:vestings).flatten
  end

  def self.active_vestings_on_product(product)
    vestings_in_won_proposals(product).select{|a| !a.expired?}.map{|b| VestingSerializer.new(b)}
  end

  def self.closed_vestings_on_product(product)
    vestings_in_won_proposals(product).select(&:expired?).map{|b| VestingSerializer.new(b)}
  end

  def self.active_contracts_on_product(product)
    Vesting.active.
      joins(:proposals).
      where(proposals: {state: ["passed", "expired"], contract_type: 'vesting', product_id: product.id})
  end

  def self.expired_contracts_on_product(product)
    Vesting.expired.
      joins(:proposals).
      where(proposals: {state: ["passed", "expired"], contract_type: 'vesting', product_id: product.id})
  end

end
