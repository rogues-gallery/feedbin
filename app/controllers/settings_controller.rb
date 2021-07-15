class SettingsController < ApplicationController
  before_action :plan_exists, only: [:update_plan]

  def settings
    @user = current_user
  end

  def account
    @user = current_user
    @last_payment = @user.billing_events
      .order(created_at: :desc)
      .where(event_type: "charge.succeeded")
      .where("created_at >= :expiration_cutoff", {expiration_cutoff: 3.days.ago})
      .take
  end

  def appearance
    @user = current_user
  end

  def billing
    @user = current_user

    @default_plan = Plan.where(price_tier: @user.price_tier, stripe_id: ["basic-yearly", "basic-yearly-2", "basic-yearly-3"]).first

    @next_payment = @user.billing_events.where(event_type: "invoice.payment_succeeded")
    @next_payment = @next_payment.to_a.sort_by { |next_payment| -next_payment.event_object["date"] }
    if @next_payment.present?
      @next_payment.first.event_object["lines"]["data"].each do |event|
        if event.dig("type") == "subscription"
          @next_payment_date = Time.at(event["period"]["end"]).utc.to_datetime
        end
      end
    end

    stripe_purchases = @user.billing_events.where(event_type: "charge.succeeded")
    in_app_purchases = @user.in_app_purchases
    all_purchases = (stripe_purchases.to_a + in_app_purchases.to_a)
    @billing_events = all_purchases.sort_by { |billing_event| billing_event.purchase_date }.reverse

    plan_setup
  end

  def edit_billing
    @user = current_user
    @default_plan = @user.plan
    plan_setup
  end

  def payment_details
    @message = Rails.cache.fetch(FeedbinUtils.payment_details_key(current_user.id)) {
      customer = Customer.retrieve(@user.customer_id)
      card = customer.sources.first
      "#{card.brand} ××#{card.last4[-2..-1]}"
    }
  rescue
    @message = "No payment info"
  end

  def import_export
    @user = current_user
    @uploader = Import.new.upload
    @uploader.success_action_redirect = settings_import_export_url
    @tags = @user.feed_tags

    @download_options = @tags.map { |tag|
      [tag.name, tag.id]
    }

    @download_options.unshift(["All", "all"])

    if params[:key]
      @import = Import.new(key: params[:key], user: @user)

      if @import.save
        @import.process
        redirect_to settings_import_export_url, notice: "Import has started."
      else
        @messages = @import.errors.full_messages
        flash[:error] = render_to_string partial: "shared/messages"
        redirect_to settings_import_export_url
      end
    end
  end

  def update_plan
    @user = current_user
    plan = Plan.find(params[:plan])
    @user.plan = plan
    @user.save
    redirect_to settings_billing_path, notice: "Plan successfully changed."
  rescue Stripe::CardError
    redirect_to settings_billing_path, alert: "Your card was declined, please update your billing information."
  end

  def update_credit_card
    @user = current_user

    if params[:stripe_token].present?
      @user.stripe_token = params[:stripe_token]
      if @user.save
        Rails.cache.delete(FeedbinUtils.payment_details_key(current_user.id))
        customer = Customer.retrieve(@user.customer_id)
        customer.reopen_account if customer.unpaid?
        redirect_to settings_billing_url, notice: "Your card has been updated."
      else
        redirect_to settings_edit_billing_url, alert: @user.errors.messages[:base].join(" ")
      end
    else
      redirect_to settings_edit_billing_url, alert: "There was a problem updating your card. Please try again."
      Librato.increment("billing.token_missing")
    end
  end

  def settings_update
    @user = current_user
    @user.attributes = user_settings_params
    if @user.save
      respond_to do |format|
        flash[:notice] = "Settings updated."
        format.js { flash.discard }
        format.html do
          if params[:redirect_to]
            redirect_to params[:redirect_to]
          else
            redirect_to settings_url
          end
        end
      end
    else
      respond_to do |format|
        flash[:alert] = @user.errors.full_messages.join(". ") + "."
        format.js { flash.discard }
        format.html do
          redirect_to settings_url
        end
      end
    end
  end

  def view_settings_update
    @user = current_user
    if params[:tag_visibility]
      tag_id = params[:tag].to_s
      if @user.tag_visibility[params[:tag]].blank?
        @user.update_tag_visibility(tag_id, true)
      else
        @user.update_tag_visibility(tag_id, false)
      end
    end

    if params[:column_widths]
      session[:column_widths] ||= {}
      session[:column_widths][params[:column]] = params[:width]
    end
    head :ok
  end

  def format
    old_settings = begin
                     JSON.parse(cookies.permanent.signed[:settings])
                   rescue
                     {}
                   end
    new_settings = user_format_params
    cookies.permanent.signed[:settings] = {
      value: JSON.generate(old_settings.merge(new_settings)),
      httponly: true,
      secure: Feedbin::Application.config.force_ssl
    }
    @user = current_user
    @user.update!(new_settings)
  end

  def sticky
    @user = current_user
    @subscription = @user.subscriptions.where(feed_id: params[:feed_id]).first
    if @subscription.present?
      @subscription.update(view_inline: !@subscription.view_inline)
    end
  end

  def subscription_view_mode
    @user = current_user
    @subscription = @user.subscriptions.where(feed_id: params[:feed_id]).first
    if @subscription.present?
      @subscription.update(subscription_view_mode_params)
    end
  end

  def now_playing
    user = current_user
    if params[:now_playing_entry]
      entry_id = params[:now_playing_entry].to_i
      if user.can_read_entry?(entry_id)
        user.update(now_playing_entry: entry_id)
      end
    end

    if params[:remove_now_playing_entry]
      user.update(now_playing_entry: nil)
    end
    head :ok
  end

  def audio_panel_size
    user = current_user
    if %w[minimized maximized].include?(params[:audio_panel_size])
      user.update(audio_panel_size: params[:audio_panel_size])
    end
    head :ok
  end

  def newsletters_pages
    @user = current_user
    @subscription_ids = @user.subscriptions.pluck(:feed_id)
  end

  private

  def plan_setup
    @plans = @user.available_plans
    @plan_data = @plans.map { |plan|
      {id: plan.id, name: plan.name, amount: plan.price_in_cents}
    }
  end

  def plan_exists
    render_404 unless Plan.exists?(params[:plan].to_i)
  end

  def user_settings_params
    params.require(:user).permit(:entry_sort, :starred_feed_enabled, :precache_images,
      :show_unread_count, :sticky_view_inline, :mark_as_read_confirmation,
      :apple_push_notification_device_token, :receipt_info, :entries_display,
      :entries_feed, :entries_time, :entries_body, :ui_typeface, :theme,
      :hide_recently_read, :hide_updated, :disable_image_proxy, :entries_image,
      :now_playing_entry, :hide_recently_played, :view_links_in_app, :newsletter_tag)
  end

  def user_now_playing_params
    params.require(:user).permit(:now_playing_entry)
  end

  def user_format_params
    params.require(:user).permit(:font_size, :theme, :font, :entry_width, :view_mode, :feeds_width, :entries_width)
  end

  def subscription_view_mode_params
    params.require(:subscription).permit(:view_mode)
  end
end
