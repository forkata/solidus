class Payment < ActiveRecord::Base
  belongs_to :order
  belongs_to :source, :polymorphic => true
  belongs_to :payment_method

  has_many :transactions
  alias :txns :transactions

  after_save :create_payment_profile, :if => :payment_profiles_supported?
  after_save :check_payments
  after_destroy :check_payments

  accepts_nested_attributes_for :source

  validate :amount_is_valid_for_outstanding_balance_or_credit
  validates :payment_method, :presence => true, :if => Proc.new { |payable| payable.is_a? Checkout }

  scope :from_creditcard, where(:source_type => 'Creditcard')
  scope :with_state, lambda {|s| where(:state => s)}
  scope :finalized, with_state('finalized')



  # order state machine (see http://github.com/pluginaweek/state_machine/tree/master for details)
  state_machine :initial => 'new' do

    # With card payments, happens before purchase or authorization happens
    event :started_processing do
      transition :from => 'new', :to => 'processing'
    end

    # When processing during checkout fails
    event :fail do
      transition :from => 'processing', :to => 'failed'
    end

    event :authorized do
      transition :from => 'processing', :to => 'authorized' 
    end

    event :finalize do
      transition :from => ['processing', 'authorized'], :to => 'finalized'
    end

    before_transition :to => 'finalized', :do => :finalize_source

  end





  # With nested attributes, Rails calls build_[association_name] for the nested model which won't work for a polymorphic association
  def build_source(params)
    if payment_method and payment_method.payment_source_class
      self.source = payment_method.payment_source_class.new(params)
    end
  end

  def process!
    if !processing? and source and source.respond_to?(:process!)
      started_processing!
      source.process!(self) # source is responsible for updating the payment state when it's done processing
    end
  end

  def can_finalize?
    processing? or authorized?
  end

  def finalize_source
    source.finalize!(self) if source and source.respond_to?(:finalize!)
    save!
    payable.save!
  end

  def actions
    return [] unless source and source.respond_to? :actions
    source.actions.select { |action| !source.respond_to?("can_#{action}?") or source.send("can_#{action}?", self) }
  end

  private

    def check_payments
      return unless order and order.complete?
      #sorting by created_at.to_f to ensure millisecond percsision, plus ID - just in case
      events = order.state_events.sort_by { |e| [e.created_at.to_f, e.id] }.reverse
      # TODO: think the below implementation will need replacing
      # if order.returnable_units.nil? && order.return_authorizations.size >0
      #   order.return!
      # elsif events.present? and %w(over_paid under_paid).include?(events.first.name)
      #   events.each do |event|
      #     if %w(shipped paid new).include?(event.previous_state)
      #       order.pay!
      #       order.update_attribute("state", event.previous_state) if %w(shipped returned).include?(event.previous_state)
      #       return
      #     end
      #   end
      # elsif order.payment_total >= order.total
      #   order.pay!
      # end
    end

    def amount_is_valid_for_outstanding_balance_or_credit
      return unless order
      if amount < 0
        if amount.abs > order.outstanding_credit
          errors.add(:amount, "Is greater than the credit owed (#{order.outstanding_credit})")
        end
      else
        if amount > order.outstanding_balance
          errors.add(:amount, "Is greater than the outstanding balance (#{order.outstanding_balance})")
        end
      end
    end

    def payment_profiles_supported?
      source && source.payment_gateway && source.payment_gateway.payment_profiles_supported?
    end

    def create_payment_profile
      return unless payment_profiles_supported? and source.number and !source.has_payment_profile?
      source.payment_gateway.create_profile(self)
    rescue ActiveMerchant::ConnectionError => e
      gateway_error I18n.t(:unable_to_connect_to_gateway)
    end

end
