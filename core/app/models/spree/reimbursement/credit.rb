module Spree
  class Reimbursement::Credit < ActiveRecord::Base
    class_attribute :default_creditable_class
    self.default_creditable_class = nil

    belongs_to :reimbursement, inverse_of: :credits
    belongs_to :creditable, polymorphic: true

    validates :creditable, presence: true

    class << self
      def total_amount_reimbursed_for(reimbursement)
        reimbursement.credits.to_a.sum(&:amount)
      end
    end

    def description
      Spree.t('credit')
    end

    def display_amount
      Spree::Money.new(amount, { currency: creditable.try(:currency) || "USD" })
    end
  end
end
