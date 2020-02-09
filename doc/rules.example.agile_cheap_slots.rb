# frozen_string_literal: true

# this rules file attempts to intelligently set charging periods overnight,
# using the cheapest energy possible with Agile half-hourly prices. it attempts
# to get your batteries up to the "required_soc" percentage. This is worked out
# on the first run after 9pm (so we have overnight Agile prices).
#
# This works best if the script knows your current SOC, which means server.rb
# needs to be accessible. If it's not, this will assume the batteries are empty.
#
# TODO: the required_soc is currently hardcoded. If you have solar panels, this
# should be high in winter (90-100%) as there will be no sun, but lower in summer,
# as otherwise you may charge your batteries using energy costing money, but then
# the sun comes out and you could have charged them for free. So lowering it in
# summer will avoid using too much imported energy. A future improvement here is
# to integrate Solcast data to try and determine exactly which days will be sunny,
# automatically.
#
# It charges if the price is 1p or less, even if the SOC is high. It also
# enables charging for an "emergency boost" if it detects a peak period is
# approaching (defined as over 15p) and your SOC is below 50%.
#
# Additionally, it turns off discharging (making the inverter idle) if the
# Agile price is "cheap enough", which varies depending on how much SOC you have.
# At 50% SOC, if we're in an Agile period that is in the lower 10th percentile
# pricing (considered over the next 10 hours), we set the inverter idle. Same for
# 20th percentile at 40% SOC, and 50th percentile at 30% SOC. This is sort of a
# middle-ground between energy that is too expensive to charge the batteries, but
# cheap enough that discharging them is not the best use of the stored power.

LOGGER.info "Current Price = #{octopus.price}p"

# constants that could move to config
battery_count = 6
charge_rate = 3.3 # kW

required_soc = 90 # TODO: solcast forecast could bias this
soc = ls.inputs['soc'] || 10 # assume 10% if we don't have it

system_size = 2.4 * battery_count # kWh per battery * number of batteries
usable_size = system_size * 0.8
charge_size = usable_size * ((required_soc - soc) / 100.0)
hours_required = charge_size / charge_rate # at a charge rate of 3.3kW
slots_required = (hours_required * 2).ceil # half-hourly Agile periods

slots_required = 0 if slots_required.negative?

LOGGER.info "SOC = #{soc}% / #{required_soc}%, " \
  "charge_size = #{charge_size.round(2)} kWh, " \
  "hours = #{hours_required.round(2)}"

# cheap_slot_data.json is our cache of what we'll be doing tonight.
# the root has two keys; slots and updated_at.
# updated_at is set to the current time when we update it, then in subsequent runs
# we know we have current data until tomorrow.
f = Pathname.new('cheap_slot_data.json')
data = f.readable? ? JSON.parse(f.read) : {}
updated_at = data['updated_at']

if Time.now.hour >= 21 && (updated_at.nil? || Time.now - Time.parse(updated_at) > 14_400)
  # if it is later than 9pm and we haven't run today, do so now
  cheapest_slots = octopus.prices
                          .take(20) # 10 hours
                          .sort_by { |_k, v| v }.to_h
                          .take(slots_required)
                          .sort.to_h

  cheapest_slots.each { |time, price| puts "#{time} #{price}p" }

  data = { 'updated_at' => Time.now, 'slots' => cheapest_slots }
  f.write(JSON.generate(data))
end

# enable charge if any of the keys in data['slots'] match the current half-hour period
now = Time.at(1800 * (Time.now.to_i / 1800))
charge = data['slots'].any? do |time, _price|
  time = Time.parse(time) unless time.is_a?(Time)
  time == now
end

LOGGER.info 'Charging due cheap_slot_data' if charge

# override for any really cheap energy as a failsafe
if octopus.price <= 1
  LOGGER.info 'Charging due to price <= 1p'
  charge = true
end

# if a peak period is approaching and we're under 50%, start emergency charge
if soc < 50 && octopus.prices.values.take(3).max > 15 && octopus.price < 15
  LOGGER.warn 'Peak approaching, emergency charging'
  charge = true
end

# depending on how much SOC we have, energy that is "cheap enough" can
# save discharge for a more expensive period.
discharge_pct = 100 # default to discharging
if octopus.prices.count > 6 # don't do this if we don't have 3 hours of future data
  # consider the next 10 hours
  sorted_by_price = octopus.prices.take(20).sort_by { |_k, v| v }.to_h.values

  c = sorted_by_price.count
  cheapest_10pct = sorted_by_price.take(c * 0.1).last
  cheapest_20pct = sorted_by_price.take(c * 0.2).last
  cheapest_50pct = sorted_by_price.take(c * 0.5).last

  LOGGER.info "Discharge cutoffs: 30%SOC = #{cheapest_50pct}p, " \
    "40%SOC = #{cheapest_20pct}p, 50%SOC = #{cheapest_10pct}p"

  if soc < 30 && octopus.price <= cheapest_50pct
    LOGGER.info 'Idle to use cheapest 50% price'
    discharge_pct = 0
  elsif soc < 40 && octopus.price <= cheapest_20pct
    LOGGER.info 'Idle to use cheapest 20% price'
    discharge_pct = 0
  elsif soc < 50 && octopus.price <= cheapest_10pct
    LOGGER.info 'Idle to use cheapest 10% price'
    discharge_pct = 0
  end
end

lc.discharge_pct = discharge_pct if lc.discharge_pct != discharge_pct

lc.charge(charge)
