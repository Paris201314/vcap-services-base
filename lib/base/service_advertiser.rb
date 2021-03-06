module VCAP::Services
  class ServiceAdvertiser
    attr_reader :logger, :active, :catalog_services, :registered_services

    def initialize(options)
      @catalog_services = options.fetch(:current_catalog)
      @registered_services = options.fetch(:catalog_in_ccdb)
      @http_handler = options.fetch(:http_handler)
      @logger = options.fetch(:logger)
      @active = options.fetch(:active, true)
      @offering_uri = "/v2/services"
      @service_plans_uri = "/v2/service_plans"

      build_service_lists_and_prepare_guids
    end

    def advertise_services
      logger.debug("CCNG Catalog Manager: Registered in ccng: #{registered_services.inspect}")
      logger.debug("CCNG Catalog Manager: Current catalog: #{catalog_services.inspect}")

      active_services.each do |active_service|
        service_in_ccdb = registered_services.find do |registered_service|
          active_service.guid == registered_service.guid
        end

        service_change_set = active_service.create_change_set(service_in_ccdb)
        logger.debug("CCNG Catalog Manager:  service_change_set = #{service_change_set.inspect}")
        advertise_service_to_cc(active_service,
                                active_service.guid,
                                service_change_set.plans_to_add,
                                service_change_set.plans_to_update)
      end

      new_services.each do |service|
        service_plan_change_set = service.create_change_set(nil)
        logger.debug("CCNG Catalog Manager: plans_to_add = #{service_plan_change_set.plans_to_add.inspect}")

        logger.debug("CCNG Catalog Manager: Add new offering: #{service.inspect}")
        advertise_service_to_cc(service, nil, service_plan_change_set.plans_to_add, {}) # nil guid => new service, so add all plans
      end

      logger.info("CCNG Catalog Manager: Found #{active_services.size} active, #{disabled_count} disabled and #{new_services.size} new service offerings")

    end

    def active_count
      active ? @catalog_services.size : 0
    end

    def disabled_count
      active ? inactive_services.size : registered_services.size
    end

    def active_services
      @active_services
    end

    def inactive_services
      @inactive_services
    end

    def new_services
      @new_services
    end

    private

    def build_service_lists_and_prepare_guids
      @inactive_services = registered_services.dup
      @active_services   = []
      @new_services      = []

      @catalog_services.each do |service|
        registered_service = registered_services.find { |rs| service.unique_id == rs.unique_id }

        unless registered_service
          registered_service = registered_services.find { |rs| service.same_tuple?(rs) }

          if registered_service && service.unique_id
            logger.warn("CCNG Catalog Manager: Service with unique id #{service.unique_id} in broker catalog matched service with unique id #{registered_service.unique_id} from cloud controller using label-version-provider tuple.")
          end
        end

        if registered_service
          service.guid = registered_service.guid
          @active_services << service
          @inactive_services.delete(registered_service)
        else
          @new_services << service
        end
      end
    end

    def add_or_update_offering(offering, guid)
      update = !guid.nil?
      uri = update ? "#{@offering_uri}/#{guid}" : @offering_uri
      service_guid = nil

      logger.debug("CCNG Catalog Manager: #{update ? "Update" : "Advertise"} service offering #{offering.inspect} to cloud_controller: #{uri}")

      offerings_hash = offering.to_hash
      method = update ? "put" : "post"
      if method == 'put'
        offerings_hash.delete('unique_id')
      end
      offerings_hash.delete('plans')
      @http_handler.cc_http_request(:uri => uri,
                                    :method => method,
                                    :body => Yajl::Encoder.encode(offerings_hash)) do |http|
        if !http.error
          if (200..299) === http.response_header.status
            response = JSON.parse(http.response)
            logger.info("CCNG Catalog Manager: Advertise offering response (code=#{http.response_header.status}): #{response.inspect}")
            service_guid = response["metadata"]["guid"]
          else
            logger.error("CCNG Catalog Manager: Failed advertise offerings:#{offering.inspect}, status=#{http.response_header.status}")
          end
        else
          logger.error("CCNG Catalog Manager: Failed advertise offerings:#{offering.inspect}: #{http.error}")
        end
      end

      return service_guid
    end

    def advertise_service_to_cc(service, guid, plans_to_add, plans_to_update)
      service_guid = add_or_update_offering(service, guid)
      return false if service_guid.nil?

      return true if !service.active # If deactivating, don't update plans

      logger.debug("CCNG Catalog Manager: Processing plans for: #{service_guid} -Add: #{plans_to_add.size} plans, Update: #{plans_to_update.size} plans")

      plans_to_add.each { |plan|
        add_plan(plan, service_guid)
      }

      plans_to_update.each { |plan|
        update_plan(plan, service_guid)
      }
      return true
    end

    def add_plan(plan, service_guid)
      uri          = @service_plans_uri
      method       = 'post'
      plan_as_hash = plan.get_add_hash(service_guid)

      logger.info("CCNG Catalog Manager: Add new plan #{plan.inspect} via #{uri}")

      make_plan_request(uri, method, plan_as_hash, plan)
    end

    def update_plan(plan, service_guid)
      uri          = "#{@service_plans_uri}/#{plan.guid}"
      method       = 'put'
      plan_as_hash = plan.get_update_hash(service_guid)

      logger.info("CCNG Catalog Manager: Update plan (guid: #{plan.guid}) to #{plan.inspect} via #{uri}")

      make_plan_request(uri, method, plan_as_hash, plan)
    end

    def make_plan_request(uri, method, plan_as_hash, plan)
      add_plan = method == 'post'

      @http_handler.cc_http_request(:uri    => uri,
                                    :method => method,
                                    :body   => Yajl::Encoder.encode(plan_as_hash)) do |http|
        if !http.error
          if (200..299) === http.response_header.status
            logger.info("CCNG Catalog Manager: Successfully #{add_plan ? "added" : "updated"} service plan: #{plan.inspect}")
            return true
          else
            logger.error("CCNG Catalog Manager: Failed to #{add_plan ? "add" : "update"} plan: #{plan.inspect}, status=#{http.response_header.status}")
          end
        else
          logger.error("CCNG Catalog Manager: Failed to #{add_plan ? "add" : "update"} plan: #{plan.inspect}: #{http.error}")
        end
      end
      return false
    end
  end
end
